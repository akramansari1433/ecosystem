package com.akram.ecosystem.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.os.Build
import android.provider.Settings
import android.util.Log
import com.akram.ecosystem.core.FrameReader
import com.akram.ecosystem.core.HelloPayload
import com.akram.ecosystem.core.Identity
import com.akram.ecosystem.core.InboundEnvelope
import com.akram.ecosystem.core.Message
import com.akram.ecosystem.core.PairingEngine
import com.akram.ecosystem.core.ProtocolCodec
import com.akram.ecosystem.core.TlsServer
import com.akram.ecosystem.ui.MainActivity
import java.io.File
import java.util.UUID
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * The always-on companion service: advertises on the LAN, accepts the Mac's TLS
 * connection, answers the control protocol, and hosts the pairing flow.
 */
class ConnectionService : Service() {

    sealed interface PairingUi {
        data class AcceptPrompt(val fingerprint: String) : PairingUi
        data class Code(val code: String) : PairingUi
    }

    data class UiState(
        val paired: Boolean = false,
        val connected: Boolean = false,
        val peerName: String? = null,
        val pairing: PairingUi? = null,
    )

    companion object {
        private const val TAG = "ConnectionService"
        private const val CHANNEL_ID = "ecosystem.status"
        private const val NOTIFICATION_ID = 1
        private const val RING_CHANNEL_ID = "ecosystem.ring"
        private const val RING_NOTIFICATION_ID = 2
        private const val ACTION_STOP_RING = "com.akram.ecosystem.STOP_RING"
        const val PROTOCOL_VERSION = 1
        val CAPABILITIES = listOf("clipboard", "ring")

        private val _state = MutableStateFlow(UiState())
        val state: StateFlow<UiState> = _state

        @Volatile
        var instance: ConnectionService? = null
            private set

        fun start(context: Context) {
            context.startForegroundService(Intent(context, ConnectionService::class.java))
        }
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private lateinit var identity: Identity
    private lateinit var advertiser: NsdAdvertiser
    private var multicastLock: WifiManager.MulticastLock? = null
    private var serverSocket: SSLServerSocket? = null
    private var session: Session? = null
    private var pairingEngine: PairingEngine? = null
    private val writeMutex = Mutex()
    private lateinit var deviceId: String
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    private val pairedPeerFile: File
        get() = File(filesDir, "paired-peer.der")

    override fun onCreate() {
        super.onCreate()
        instance = this
        identity = Identity.loadOrCreate(filesDir)
        deviceId = deviceIdFor(this)
        advertiser = NsdAdvertiser(this)
        createChannel()
        startForeground(
            NOTIFICATION_ID, buildNotification("Waiting for your Mac…"),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        multicastLock = getSystemService(WifiManager::class.java)
            .createMulticastLock("ecosystem-nsd").apply { acquire() }
        _state.value = UiState(paired = pairedPeerFile.exists())
        scope.launch { serverLoop() }
        watchNetwork()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP_RING) stopRinging(notifyMac = true)
        return START_STICKY
    }

    override fun onBind(intent: Intent?) = null

    override fun onDestroy() {
        instance = null
        advertiser.unregister()
        multicastLock?.release()
        runCatching { serverSocket?.close() }
        scope.cancel()
        super.onDestroy()
    }

    // MARK: server

    private suspend fun serverLoop() {
        while (true) {
            try {
                // One server for the process lifetime; the trust manager reads the
                // current pin per handshake, so pairing never changes the port.
                val server = TlsServer(identity) {
                    pairedPeerFile.takeIf { it.exists() }?.readBytes()
                }.listen()
                serverSocket = server
                advertiser.register(server.localPort, deviceId, deviceName(), PROTOCOL_VERSION)
                Log.i(TAG, "listening on ${server.localPort}")
                while (true) {
                    val socket = server.accept() as SSLSocket
                    // Handle concurrently: a stale session (e.g. the Mac app was
                    // killed mid-connection) must never block new connections.
                    scope.launch {
                        runCatching { socket.startHandshake() }
                            .onFailure { Log.w(TAG, "handshake failed: $it"); socket.close() }
                            .onSuccess { handleConnection(socket) }
                    }
                }
            } catch (t: Throwable) {
                Log.e(TAG, "server loop error", t)
                kotlinx.coroutines.delay(3000)
            }
        }
    }

    /** Runs one control connection to completion (blocking in IO dispatcher). */
    private fun handleConnection(socket: SSLSocket) {
        val peerDer = TlsServer.peerDer(socket)
        // The newest connection wins: drop any previous (likely stale) session.
        session?.close()
        // Dead-peer watchdog: the Mac pings every 10 s; 35 s of silence means the
        // connection is gone even if TCP never noticed (Wi-Fi drop, app killed).
        socket.soTimeout = 35_000
        val s = Session(socket)
        session = s
        if (!pairedPeerFile.exists()) {
            pairingEngine = PairingEngine(
                PairingEngine.Role.RESPONDER, ownDer = identity.certDer, peerDer = peerDer)
        }
        try {
            sendMessage(Message.Hello(HelloPayload(
                capabilities = CAPABILITIES, deviceId = deviceId,
                name = deviceName(), protocolVersion = PROTOCOL_VERSION)))
            val reader = FrameReader()
            val input = socket.inputStream
            val buf = ByteArray(32 * 1024)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                for (frame in reader.append(buf.copyOf(n))) {
                    dispatch(ProtocolCodec.decodeFrame(frame))
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "connection ended: $t")
        } finally {
            runCatching { socket.close() }
            // Only clear state if WE are still the active session — a newer
            // connection may already have replaced this one.
            if (session === s) {
                session = null
                pairingEngine = null
                _state.value = _state.value.copy(
                    connected = false, peerName = null, pairing = null)
                updateNotification("Waiting for your Mac…")
            }
        }
    }

    private fun dispatch(envelope: InboundEnvelope) {
        when (val m = envelope.message) {
            is Message.Hello -> {
                if (m.payload.protocolVersion != PROTOCOL_VERSION) {
                    sendMessage(Message.Error(
                        com.akram.ecosystem.core.ErrorPayload("version_mismatch")))
                    session?.close()
                    return
                }
                _state.value = _state.value.copy(connected = true, peerName = m.payload.name)
                updateNotification("Connected to ${m.payload.name}")
            }
            Message.Ping -> sendMessage(Message.Pong, replyTo = envelope.id)
            is Message.PairRequest ->
                handlePairingInput(PairingEngine.Input.ReceivedRequest(m.payload.certFingerprint))
            Message.PairConfirm -> handlePairingInput(PairingEngine.Input.ReceivedConfirm)
            is Message.PairAbort ->
                handlePairingInput(PairingEngine.Input.ReceivedAbort(m.payload.reason))
            is Message.ClipboardSet -> clipboardHandler.applyRemote(m.payload)
            Message.RingStart -> startRinging()
            Message.RingStop -> stopRinging(notifyMac = false)
            else -> Log.d(TAG, "ignoring ${m.typeString}")
        }
    }

    // MARK: pairing

    fun userAccepted() = handlePairingInput(PairingEngine.Input.UserAccepted)
    fun userConfirmed() = handlePairingInput(PairingEngine.Input.UserConfirmed)
    fun userRejected() = handlePairingInput(PairingEngine.Input.UserRejected)

    private fun handlePairingInput(input: PairingEngine.Input) {
        val engine = pairingEngine ?: return
        val session = session ?: return
        for (effect in engine.handle(input)) {
            when (effect) {
                is PairingEngine.Effect.Send -> sendMessage(effect.message)
                is PairingEngine.Effect.ShowAcceptPrompt ->
                    _state.value = _state.value.copy(
                        pairing = PairingUi.AcceptPrompt(effect.fingerprint))
                is PairingEngine.Effect.DisplayCode ->
                    _state.value = _state.value.copy(pairing = PairingUi.Code(effect.code))
                PairingEngine.Effect.PersistPeerCert ->
                    pairedPeerFile.writeBytes(TlsServer.peerDer(session.socket))
                PairingEngine.Effect.Complete -> {
                    _state.value = _state.value.copy(paired = true, pairing = null)
                    // Reconnect in pinned mode: drop the connection; Mac re-dials.
                    session.close()
                }
                is PairingEngine.Effect.Fail -> {
                    _state.value = _state.value.copy(pairing = null)
                    Log.i(TAG, "pairing failed: ${effect.reason}")
                }
            }
        }
    }

    /** Clears the pairing so a new Mac can pair (Settings action). */
    fun unpair() {
        pairedPeerFile.delete()
        session?.close()
        _state.value = _state.value.copy(paired = false)
    }

    // MARK: clipboard

    private val clipboardHandler by lazy {
        com.akram.ecosystem.features.ClipboardHandler(this)
    }

    /** Sends [text] to the Mac. Returns false when disconnected or a repeat. */
    fun sendLocalClipboard(text: String): Boolean {
        if (session == null) {
            Log.i(TAG, "clipboard: no session; not sending")
            return false
        }
        if (!clipboardHandler.shouldSend(text)) {
            Log.i(TAG, "clipboard: suppressing echo/repeat")
            return false
        }
        Log.i(TAG, "clipboard: sending ${text.length} chars")
        clipboardHandler.markSent(text)
        sendMessage(Message.ClipboardSet(
            com.akram.ecosystem.core.ClipboardSetPayload(
                text = text, tsMillis = System.currentTimeMillis())))
        return true
    }

    // MARK: ring

    private val ringPlayer by lazy { com.akram.ecosystem.features.RingPlayer(this) }
    private var ringTimeout: kotlinx.coroutines.Job? = null

    private fun startRinging() {
        ringPlayer.start()
        showRingNotification()
        ringTimeout?.cancel()
        ringTimeout = scope.launch {
            kotlinx.coroutines.delay(60_000)
            stopRinging(notifyMac = true)
        }
    }

    private fun stopRinging(notifyMac: Boolean) {
        ringTimeout?.cancel()
        if (ringPlayer.isRinging) {
            ringPlayer.stop()
            getSystemService(NotificationManager::class.java).cancel(RING_NOTIFICATION_ID)
            if (notifyMac) sendMessage(Message.RingStopped)
        }
    }

    private fun showRingNotification() {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(
                RING_CHANNEL_ID, "Find my phone", NotificationManager.IMPORTANCE_HIGH))
        val stop = PendingIntent.getService(
            this, 1,
            Intent(this, ConnectionService::class.java).setAction(ACTION_STOP_RING),
            PendingIntent.FLAG_IMMUTABLE)
        nm.notify(
            RING_NOTIFICATION_ID,
            Notification.Builder(this, RING_CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
                .setContentTitle("Your Mac is ringing this phone")
                .setOngoing(true)
                .addAction(Notification.Action.Builder(null, "Stop", stop).build())
                .build())
    }

    // MARK: outbound

    fun sendMessage(message: Message, replyTo: String? = null) {
        val s = session ?: return
        scope.launch {
            writeMutex.withLock {
                runCatching {
                    s.socket.outputStream.write(
                        ProtocolCodec.encodeFrame(
                            id = UUID.randomUUID().toString(), message = message,
                            replyTo = replyTo))
                    s.socket.outputStream.flush()
                }.onFailure { Log.w(TAG, "send failed: $it") }
            }
        }
    }

    // MARK: plumbing

    private class Session(val socket: SSLSocket) {
        fun close() = runCatching { socket.close() }
    }

    private fun watchNetwork() {
        val cm = getSystemService(ConnectivityManager::class.java)
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                serverSocket?.localPort?.takeIf { it > 0 }?.let {
                    advertiser.register(it, deviceId, deviceName(), PROTOCOL_VERSION)
                }
            }
        }
        networkCallback = callback
        cm.registerNetworkCallback(
            NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(),
            callback)
    }

    private fun deviceName(): String =
        Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME)
            ?: Build.MODEL

    private fun deviceIdFor(context: Context): String {
        val prefs = context.getSharedPreferences("ecosystem", MODE_PRIVATE)
        return prefs.getString("deviceId", null) ?: UUID.randomUUID().toString()
            .also { prefs.edit().putString("deviceId", it).apply() }
    }

    private fun createChannel() {
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID, "Connection status", NotificationManager.IMPORTANCE_MIN))
    }

    private fun buildNotification(text: String): Notification {
        val tap = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle("Ecosystem")
            .setContentText(text)
            .setContentIntent(tap)
            .setOngoing(true)
            .build()
    }

    private fun updateNotification(text: String) {
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, buildNotification(text))
    }
}
