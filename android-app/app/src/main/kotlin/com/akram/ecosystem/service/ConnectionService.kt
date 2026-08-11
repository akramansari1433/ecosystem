package com.akram.ecosystem.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.os.Build
import android.provider.Settings
import android.util.Log
import com.akram.ecosystem.core.BinaryFrames
import com.akram.ecosystem.core.ErrorPayload
import com.akram.ecosystem.core.FileService
import com.akram.ecosystem.core.FrameReader
import com.akram.ecosystem.core.FsEntriesPayload
import com.akram.ecosystem.core.FsTransferReadyPayload
import com.akram.ecosystem.core.FsTransferResultPayload
import com.akram.ecosystem.core.FsUploadPayload
import com.akram.ecosystem.core.HelloPayload
import com.akram.ecosystem.core.Identity
import com.akram.ecosystem.core.InboundEnvelope
import com.akram.ecosystem.core.Message
import com.akram.ecosystem.core.PairedPeers
import com.akram.ecosystem.core.PairingEngine
import com.akram.ecosystem.core.PairingSecret
import com.akram.ecosystem.core.ProtocolCodec
import com.akram.ecosystem.core.StreamAttachPayload
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
        /** Names of every Mac connected right now. */
        val connectedPeers: List<String> = emptyList(),
        val pairing: PairingUi? = null,
        val mirrorConsentPending: Boolean = false,
        val cameraPermissionNeeded: Boolean = false,
        val cameraActive: Boolean = false,
    )

    companion object {
        private const val TAG = "ConnectionService"
        private const val CHANNEL_ID = "ecosystem.status"
        private const val NOTIFICATION_ID = 1
        private const val RING_CHANNEL_ID = "ecosystem.ring"
        private const val RING_NOTIFICATION_ID = 2
        private const val CONSENT_NOTIFICATION_ID = 3
        /** Keep capture warm this long after the Mac closes, for instant re-open. */
        private const val MIRROR_IDLE_TIMEOUT_MS = 10 * 60 * 1000L
        private const val ACTION_STOP_RING = "com.akram.ecosystem.STOP_RING"
        const val PROTOCOL_VERSION = 2

        /** "input" appears only while the accessibility service is actually
         *  connected, so the Mac can tell the user when control is unavailable. */
        val capabilities: List<String>
            get() = buildList {
                addAll(listOf("clipboard", "ring", "fs", "mirror", "camera"))
                if (com.akram.ecosystem.accessibility.RemoteInput.isAvailable) add("input")
            }

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
    /** One entry per connected Mac, keyed by its device id. */
    private val sessions = java.util.concurrent.ConcurrentHashMap<String, Session>()
    private var pairingEngine: PairingEngine? = null
    private var pendingPairNonce: ByteArray? = null
    private var pairingSession: Session? = null
    private lateinit var deviceId: String
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        identity = Identity.loadOrCreate(filesDir)
        File(filesDir, "paired-peer.der").delete() // pre-HMAC pairing leftover
        deviceId = deviceIdFor(this)
        advertiser = NsdAdvertiser(this)
        createChannel()
        startForeground(
            NOTIFICATION_ID, buildNotification("Waiting for your Mac…"),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        multicastLock = getSystemService(WifiManager::class.java)
            .createMulticastLock("ecosystem-nsd").apply { acquire() }
        _state.value = UiState(paired = !PairedPeers.isEmpty(filesDir))
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
                // One server for the process lifetime: pairing must never change
                // the port, or the Mac keeps dialling a stale mDNS record.
                val server = TlsServer(identity).listen()
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

    /**
     * The client speaks first (docs/protocol.md §4): its first frame decides
     * whether this is the control connection (hello) or a stream (stream.attach).
     */
    private fun handleConnection(socket: SSLSocket) {
        socket.soTimeout = 35_000
        socket.tcpNoDelay = true // small frames must not wait for Nagle coalescing
        val reader = FrameReader()
        val input = socket.inputStream
        val buf = ByteArray(32 * 1024)
        val pending = ArrayDeque<InboundEnvelope>()
        try {
            while (pending.isEmpty()) {
                val n = input.read(buf)
                if (n < 0) {
                    socket.close(); return
                }
                reader.append(buf.copyOf(n)).forEach {
                    pending += ProtocolCodec.decodeFrame(it)
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "first-frame read failed: $t")
            runCatching { socket.close() }
            return
        }
        when (val first = pending.removeFirst().message) {
            is Message.Hello -> runControl(socket, reader, buf, first, pending)
            is Message.StreamAttach -> runStream(socket, reader, first.payload)
            else -> {
                // Closing silently made a mis-ordered client look like a dropped
                // connection; say what happened so the far end can report it.
                Log.w(TAG, "unexpected first frame ${first.typeString}; expected hello")
                runCatching {
                    socket.outputStream.write(ProtocolCodec.encodeFrame(
                        id = UUID.randomUUID().toString(),
                        message = Message.Error(ErrorPayload(
                            "expected_hello",
                            "First frame must be hello, got ${first.typeString}"))))
                    socket.outputStream.flush()
                }
                runCatching { socket.close() }
            }
        }
    }

    private fun runControl(
        socket: SSLSocket,
        reader: FrameReader,
        buf: ByteArray,
        hello: Message.Hello,
        pending: ArrayDeque<InboundEnvelope>,
    ) {
        val peerId = hello.payload.deviceId
        // Only replace a session from the *same* Mac (a reconnect). Another Mac's
        // session stays up: both can be paired and connected at once.
        sessions.remove(peerId)?.close()
        val s = Session(socket, peerId, hello.payload.name)
        sessions[peerId] = s
        try {
            if (hello.payload.protocolVersion != PROTOCOL_VERSION) {
                s.send(Message.Error(ErrorPayload("version_mismatch")))
                return
            }
            s.send(Message.Hello(HelloPayload(
                capabilities = capabilities, deviceId = deviceId,
                name = deviceName(), protocolVersion = PROTOCOL_VERSION)))

            val recognised = PairedPeers.secretFor(filesDir, peerId) != null ||
                PairedPeers.legacySecret(filesDir) != null
            if (recognised) {
                // Known Macs prove they hold their own secret before being served.
                val nonce = PairingSecret.newNonce()
                s.authChallenge = nonce
                @OptIn(ExperimentalStdlibApi::class)
                s.send(Message.AuthChallenge(
                    com.akram.ecosystem.core.AuthChallengePayload(nonce.toHexString())))
            } else {
                // A Mac we do not know must prove nothing — it earns access only
                // by pairing, which the user approves on this phone. Granting it
                // a session here would let any Mac on the network walk in.
                s.send(Message.Error(ErrorPayload(
                    "pair_required", "This Mac is not paired with the phone yet")))
            }
            pending.forEach { dispatch(it, s) }
            val input = socket.inputStream
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                for (frame in reader.append(buf.copyOf(n))) {
                    dispatch(ProtocolCodec.decodeFrame(frame), s)
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "control connection ended: $t")
        } finally {
            runCatching { socket.close() }
            if (sessions[peerId] === s) {
                sessions.remove(peerId)
                if (pairingSession === s) {
                    pairingSession = null
                    pairingEngine = null
                    _state.value = _state.value.copy(pairing = null)
                }
                publishConnectionState()
            }
        }
    }

    /** Reflects however many Macs are connected in the UI and the notification. */
    private fun publishConnectionState() {
        val connected = sessions.values.filter { it.authenticated }
        val names = connected.map { it.name }
        _state.value = _state.value.copy(
            connected = connected.isNotEmpty(),
            peerName = names.firstOrNull(),
            connectedPeers = names)
        updateNotification(when (names.size) {
            0 -> "Waiting for your Mac…"
            1 -> "Connected to ${names.first()}"
            else -> "Connected to ${names.size} Macs"
        })
    }

    /** Sends to every authenticated Mac: clipboard changes, ring notifications. */
    private fun broadcast(message: Message) {
        sessions.values.filter { it.authenticated }.forEach { it.send(message) }
    }

    private fun dispatch(envelope: InboundEnvelope, session: Session) {
        val message = envelope.message
        // Everything except the handshake requires an authenticated peer.
        if (!session.authenticated) {
            when (message) {
                is Message.AuthResponse, Message.Ping, is Message.PairRequest,
                Message.PairConfirm, is Message.PairAbort -> Unit
                else -> {
                    Log.w(TAG, "dropping ${message.typeString} before auth")
                    return
                }
            }
        }
        when (val m = message) {
            is Message.AuthResponse -> authenticate(session, m.payload.mac)
            Message.Ping -> session.send(Message.Pong, replyTo = envelope.id)
            is Message.PairRequest -> handlePairingInput(
                PairingEngine.Input.ReceivedRequest(m.payload.certFingerprint), session)
            Message.PairConfirm ->
                handlePairingInput(PairingEngine.Input.ReceivedConfirm, session)
            is Message.PairAbort -> handlePairingInput(
                PairingEngine.Input.ReceivedAbort(m.payload.reason), session)
            is Message.ClipboardSet -> {
                clipboardHandler.applyRemote(m.payload)
                // Keep the other Macs in step with what was just copied.
                sessions.values
                    .filter { it.authenticated && it !== session }
                    .forEach { it.send(m) }
            }
            Message.RingStart -> startRinging()
            Message.RingStop -> stopRinging(notifyMac = false)
            is Message.FsList -> handleFsList(session, envelope.id, m.payload.path)
            is Message.FsSearch -> handleFsSearch(session, envelope.id, m.payload)
            is Message.FsThumb -> handleFsThumb(session, envelope.id, m.payload)
            is Message.FsDownload -> handleFsDownload(session, envelope.id, m.payload.path)
            is Message.FsUpload -> handleFsUpload(session, envelope.id, m.payload)
            is Message.FsTransferResult ->
                Log.i(TAG, "transfer ${m.payload.token}: ok=${m.payload.ok}")
            is Message.MirrorStart -> handleMirrorStart(session, envelope.id, m.payload)
            Message.MirrorStop -> pauseMirroring()
            is Message.CameraStart -> handleCameraStart(session, envelope.id, m.payload)
            Message.CameraList -> session.send(
                Message.CameraCameras(com.akram.ecosystem.core.CameraListPayload(
                    com.akram.ecosystem.features.CameraCatalog.list(this))),
                replyTo = envelope.id)
            is Message.CameraZoom -> cameraStreamer?.setZoom(m.payload.ratio)
            Message.CameraStop -> stopCamera()
            is Message.InputTap -> {
                val (w, h) = screenSize()
                com.akram.ecosystem.accessibility.RemoteInput.tap(
                    (m.payload.x * w).toFloat(), (m.payload.y * h).toFloat(),
                    m.payload.longPress)
            }
            is Message.InputSwipe -> {
                val (w, h) = screenSize()
                com.akram.ecosystem.accessibility.RemoteInput.swipe(
                    (m.payload.x1 * w).toFloat(), (m.payload.y1 * h).toFloat(),
                    (m.payload.x2 * w).toFloat(), (m.payload.y2 * h).toFloat(),
                    m.payload.durationMs.toLong())
            }
            is Message.InputKey -> when (m.payload.key) {
                "dim.on" -> com.akram.ecosystem.accessibility.RemoteInput.setDimmed(true)
                "dim.off" -> com.akram.ecosystem.accessibility.RemoteInput.setDimmed(false)
                "volume.up" -> adjustVolume(AudioManager.ADJUST_RAISE)
                "volume.down" -> adjustVolume(AudioManager.ADJUST_LOWER)
                "volume.mute" -> adjustVolume(AudioManager.ADJUST_TOGGLE_MUTE)
                else ->
                    com.akram.ecosystem.accessibility.RemoteInput.globalAction(m.payload.key)
            }
            is Message.InputText ->
                com.akram.ecosystem.accessibility.RemoteInput.typeText(m.payload.text)
            is Message.InputScroll -> {
                val (w, h) = screenSize()
                com.akram.ecosystem.accessibility.RemoteInput.scroll(
                    m.payload.phase, (m.payload.x * w).toFloat(), (m.payload.y * h).toFloat())
            }
            else -> Log.d(TAG, "ignoring ${m.typeString}")
        }
    }

    // MARK: files

    private val fileService by lazy {
        FileService(android.os.Environment.getExternalStorageDirectory())
    }

    private fun storageGranted() = android.os.Environment.isExternalStorageManager()

    private fun handleFsList(session: Session, requestId: String, path: String) {
        if (!storageGranted()) {
            sendMessage(Message.Error(ErrorPayload("storage_permission",
                "Grant 'All files access' in the Ecosystem app")), replyTo = requestId)
            return
        }
        // Off the reader thread: a slow storage stat must never delay ping/pong
        // or other replies queued behind it.
        scope.launch {
            runCatching { fileService.list(path) }
                .onSuccess {
                    session.send(Message.FsEntries(FsEntriesPayload(it)), replyTo = requestId)
                }
                .onFailure {
                    sendMessage(Message.Error(ErrorPayload("fs_error", it.message)),
                        replyTo = requestId)
                }
        }
    }

    private val videoExtensions = setOf("mp4", "mkv", "mov", "webm", "3gp", "avi")
    private val imageExtensions =
        setOf("jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "dng")

    private fun handleFsSearch(
        session: Session,
        requestId: String,
        payload: com.akram.ecosystem.core.FsSearchPayload,
    ) {
        if (!storageGranted()) {
            sendMessage(Message.Error(ErrorPayload("storage_permission",
                "Grant 'All files access' in the Ecosystem app")), replyTo = requestId)
            return
        }
        scope.launch {
            val extensions = buildSet {
                if ("image" in payload.kinds) addAll(imageExtensions)
                if ("video" in payload.kinds) addAll(videoExtensions)
            }
            runCatching { fileService.search(payload.path, extensions, payload.maxDepth) }
                .onSuccess {
                    Log.i(TAG, "search ${payload.path} ${payload.kinds} -> ${it.size} files")
                    session.send(Message.FsEntries(FsEntriesPayload(it)), replyTo = requestId)
                }
                .onFailure {
                    sendMessage(Message.Error(ErrorPayload("fs_error", it.message)),
                        replyTo = requestId)
                }
        }
    }

    // At most 2 concurrent decodes: HEIC decoding is CPU-heavy and must not
    // starve listings and transfers sharing the connection.
    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    private val thumbDispatcher = Dispatchers.IO.limitedParallelism(2)

    private fun handleFsThumb(session: Session, requestId: String, payload: com.akram.ecosystem.core.FsThumbPayload) {
        scope.launch(thumbDispatcher) {
            val size = android.util.Size(payload.maxEdge, payload.maxEdge)
            val bitmap = runCatching {
                val file = fileService.resolve(payload.path)
                if (file.extension.lowercase() in videoExtensions) {
                    android.media.ThumbnailUtils.createVideoThumbnail(file, size, null)
                } else {
                    android.media.ThumbnailUtils.createImageThumbnail(file, size, null)
                }
            }.getOrNull()
            val base64 = bitmap?.let {
                val out = java.io.ByteArrayOutputStream()
                it.compress(android.graphics.Bitmap.CompressFormat.JPEG, 70, out)
                it.recycle()
                android.util.Base64.encodeToString(out.toByteArray(), android.util.Base64.NO_WRAP)
            }
            sendMessage(Message.FsThumbData(
                com.akram.ecosystem.core.FsThumbDataPayload(base64)), replyTo = requestId)
        }
    }

    private fun handleFsDownload(session: Session, requestId: String, path: String) {
        runCatching { fileService.prepareDownload(path) }
            .onSuccess {
                sendMessage(Message.FsTransferReady(
                    FsTransferReadyPayload(size = it.size, token = it.token)),
                    replyTo = requestId)
            }
            .onFailure {
                sendMessage(Message.Error(ErrorPayload("fs_error", it.message)),
                    replyTo = requestId)
            }
    }

    private fun handleFsUpload(session: Session, requestId: String, payload: FsUploadPayload) {
        runCatching { fileService.prepareUpload(payload.destPath, payload.size) }
            .onSuccess {
                sendMessage(Message.FsTransferReady(FsTransferReadyPayload(token = it)),
                    replyTo = requestId)
            }
            .onFailure {
                sendMessage(Message.Error(ErrorPayload("fs_error", it.message)),
                    replyTo = requestId)
            }
    }

    /** Routes an attached stream connection by kind (file transfer / mirror). */
    private fun runStream(socket: SSLSocket, reader: FrameReader, attach: StreamAttachPayload) {
        try {
            // Video streams are one-way: the Mac sends nothing once attached, so
            // the control connection's 35s read timeout would end them mid-session.
            if (attach.kind == "mirror" || attach.kind == "camera") socket.soTimeout = 0
            when (attach.kind) {
                "mirror" -> {
                    if (attach.token == mirrorToken) {
                        runMirrorStream(socket)
                    } else {
                        Log.w(TAG, "unknown mirror token")
                    }
                }
                "camera" -> {
                    if (attach.token == cameraToken) {
                        runCameraStream(socket)
                    } else {
                        Log.w(TAG, "unknown camera token")
                    }
                }
                "file" -> {
                    fileService.takeDownload(attach.token)?.let { file ->
                        streamFileOut(socket, file)
                        return
                    }
                    fileService.takeUpload(attach.token)?.let { pending ->
                        streamFileIn(socket, reader, pending, attach.token)
                        return
                    }
                    Log.w(TAG, "unknown stream token")
                }
                else -> Log.w(TAG, "unsupported stream kind ${attach.kind}")
            }
        } catch (t: Throwable) {
            Log.w(TAG, "stream ended with error: $t")
        } finally {
            runCatching { socket.close() }
        }
    }

    private fun streamFileOut(socket: SSLSocket, file: File) {
        Log.i(TAG, "sending ${file.name} (${file.length()} bytes)")
        val out = socket.outputStream
        file.inputStream().use { input ->
            val chunk = ByteArray(BinaryFrames.FILE_CHUNK_BYTES)
            var offset = 0L
            while (true) {
                val n = input.read(chunk)
                if (n < 0) break
                out.write(BinaryFrames.encode(
                    BinaryFrames.TYPE_FILE_CHUNK, offset, chunk.copyOf(n)))
                offset += n
            }
        }
        out.write(BinaryFrames.encode(BinaryFrames.TYPE_END, 0, ByteArray(0)))
        out.flush()
    }

    private fun streamFileIn(
        socket: SSLSocket,
        jsonReader: FrameReader,
        pending: FileService.PendingUpload,
        token: String,
    ) {
        Log.i(TAG, "receiving ${pending.dest.name} (${pending.size} bytes)")
        val temp = File(cacheDir, "upload-$token.part")
        val digest = java.security.MessageDigest.getInstance("SHA-256")
        val frameReader = com.akram.ecosystem.core.BinaryFrameReader()
        var done = false
        temp.outputStream().use { out ->
            // Bytes that arrived coalesced with the attach frame belong to us.
            for (frame in frameReader.append(jsonReader.drainBuffered())) {
                if (frame.frameType == BinaryFrames.TYPE_END) done = true
                else { out.write(frame.payload); digest.update(frame.payload) }
            }
            val buf = ByteArray(64 * 1024)
            val input = socket.inputStream
            while (!done) {
                val n = input.read(buf)
                if (n < 0) break
                for (frame in frameReader.append(buf.copyOf(n))) {
                    if (frame.frameType == BinaryFrames.TYPE_END) { done = true; break }
                    out.write(frame.payload)
                    digest.update(frame.payload)
                }
            }
        }
        val ok = done && temp.length() == pending.size
        if (ok) {
            pending.dest.parentFile?.mkdirs()
            if (!temp.renameTo(pending.dest)) {
                temp.copyTo(pending.dest, overwrite = true)
                temp.delete()
            }
        } else {
            temp.delete()
        }
        @OptIn(ExperimentalStdlibApi::class)
        sendMessage(Message.FsTransferResult(FsTransferResultPayload(
            ok = ok, sha256 = digest.digest().toHexString(), token = token)))
        Log.i(TAG, "upload ${pending.dest.name}: ok=$ok")
    }

    // MARK: pairing

    fun userAccepted() = handlePairingInput(PairingEngine.Input.UserAccepted)
    fun userConfirmed() = handlePairingInput(PairingEngine.Input.UserConfirmed)
    fun userRejected() = handlePairingInput(PairingEngine.Input.UserRejected)

    private fun handlePairingInput(input: PairingEngine.Input, session: Session? = null) {
        // The Mac's nonce arrives as the pair.request "fingerprint"; rebuild the
        // engine with it so both sides derive the same verification code.
        if (input is PairingEngine.Input.ReceivedRequest) {
            @OptIn(ExperimentalStdlibApi::class)
            val nonce = runCatching { input.fingerprint.hexToByteArray() }.getOrNull()
            if (nonce == null) {
                Log.w(TAG, "malformed pairing nonce")
                return
            }
            pendingPairNonce = nonce
            pairingSession = session
            pairingEngine = PairingEngine(
                PairingEngine.Role.RESPONDER, ownDer = identity.certDer, peerDer = nonce)
        }
        val engine = pairingEngine ?: return
        val session = session ?: return
        for (effect in engine.handle(input)) {
            when (effect) {
                is PairingEngine.Effect.Send -> session.send(effect.message)
                is PairingEngine.Effect.ShowAcceptPrompt ->
                    _state.value = _state.value.copy(
                        pairing = PairingUi.AcceptPrompt(session.name))
                is PairingEngine.Effect.DisplayCode ->
                    _state.value = _state.value.copy(pairing = PairingUi.Code(effect.code))
                PairingEngine.Effect.PersistPeerCert ->
                    pendingPairNonce?.let { nonce ->
                        // Stored against this Mac's device id, so pairing a second
                        // Mac leaves the first one paired.
                        PairedPeers.add(
                            filesDir, session.peerId, session.name,
                            PairingSecret.derive(nonce, identity.certDer))
                    }
                PairingEngine.Effect.Complete -> {
                    _state.value = _state.value.copy(paired = true, pairing = null)
                    pendingPairNonce = null
                    pairingSession = null
                    pairingEngine = null
                    // Reconnect authenticated: drop the connection; the Mac re-dials.
                    session.close()
                }
                is PairingEngine.Effect.Fail -> {
                    _state.value = _state.value.copy(pairing = null)
                    Log.i(TAG, "pairing failed: ${effect.reason}")
                }
            }
        }
    }

    // MARK: clipboard

    private val clipboardHandler by lazy {
        com.akram.ecosystem.features.ClipboardHandler(this)
    }

    /** Marks text as already-seen so our own clipboard writes are not echoed. */
    fun suppressClipboard(text: String) {
        clipboardHandler.markSent(text)
    }

    /** Sends [text] to every connected Mac. False when none, or it is a repeat. */
    fun sendLocalClipboard(text: String): Boolean {
        if (sessions.values.none { it.authenticated }) {
            Log.i(TAG, "clipboard: nothing connected; not sending")
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

    /** Media volume, with the phone's own volume panel shown as feedback. */
    private fun adjustVolume(direction: Int) {
        getSystemService(AudioManager::class.java).adjustStreamVolume(
            AudioManager.STREAM_MUSIC, direction, AudioManager.FLAG_SHOW_UI)
    }

    /** Current screen size in pixels; input arrives normalized to it. */
    private fun screenSize(): Pair<Int, Int> {
        val bounds = getSystemService(android.view.WindowManager::class.java)
            .maximumWindowMetrics.bounds
        return bounds.width() to bounds.height()
    }

    // MARK: mirroring

    /** One-shot consent grant handed over by MainActivity. */
    @Volatile
    private var projectionGrant: Pair<Int, Intent>? = null

    /** Kept alive between sessions so mirroring only needs approving once. */
    @Volatile
    private var liveProjection: android.media.projection.MediaProjection? = null
    private var mirrorEncoder: com.akram.ecosystem.features.MirrorEncoder? = null
    private var mirrorToken: String? = null
    private var mirrorWidth = 0
    private var mirrorHeight = 0
    private var idleMirrorJob: kotlinx.coroutines.Job? = null
    private var pendingMirrorFrames = ArrayDeque<Triple<Int, Long, ByteArray>>()
    @Volatile
    private var mirrorSocket: SSLSocket? = null
    private val mirrorWriteLock = Any()

    @Volatile
    private var consentPromptShown = false

    fun setProjectionGrant(resultCode: Int, data: Intent) {
        projectionGrant = resultCode to data
        consentPromptShown = false
        getSystemService(NotificationManager::class.java).cancel(CONSENT_NOTIFICATION_ID)
        _state.value = _state.value.copy(mirrorConsentPending = false)
        Log.i(TAG, "projection consent granted")
    }

    fun consentDenied() {
        consentPromptShown = false
        getSystemService(NotificationManager::class.java).cancel(CONSENT_NOTIFICATION_ID)
        _state.value = _state.value.copy(mirrorConsentPending = false)
    }

    private fun handleMirrorStart(
        session: Session,
        requestId: String,
        payload: com.akram.ecosystem.core.MirrorStartPayload,
    ) {
        val grant = projectionGrant
        if (grant == null && liveProjection == null) {
            _state.value = _state.value.copy(mirrorConsentPending = true)
            // The Mac polls every 2 s while waiting; prompt the user only once.
            if (!consentPromptShown) {
                consentPromptShown = true
                showConsentNotification()
                runCatching {
                    startActivity(
                        Intent(this, com.akram.ecosystem.ui.MainActivity::class.java)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or
                                Intent.FLAG_ACTIVITY_SINGLE_TOP)
                            .putExtra("requestProjection", true))
                }
            }
            session.send(Message.MirrorNeedsConsent, replyTo = requestId)
            return
        }
        consentPromptShown = false
        // Android 14+ allows only ONE capture per consent, so a running session
        // is reused rather than rebuilt — that is what makes mirroring instant
        // on the second and later opens.
        wakeScreenForMirroring()
        mirrorEncoder?.takeIf { it.isRunning }?.let { encoder ->
            val token = UUID.randomUUID().toString()
            mirrorToken = token
            detachMirrorStream()
            encoder.cachedConfig()?.let {
                emitMirrorFrame(BinaryFrames.TYPE_CODEC_CONFIG, 0, it)
            }
            encoder.requestKeyframe()
            sendMessage(Message.MirrorStarted(
                com.akram.ecosystem.core.MirrorStartedPayload(
                    height = mirrorHeight, rotationDeg = 0,
                    token = token, width = mirrorWidth)),
                replyTo = requestId)
            Log.i(TAG, "reusing live capture session")
            return
        }
        try {
            // API 34+: the service must be foregrounded with the mediaProjection
            // type BEFORE getMediaProjection, and a callback registered before
            // createVirtualDisplay.
            startForeground(
                NOTIFICATION_ID, buildNotification("Mirroring to your Mac"),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE or
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
            // Reuse a live projection so the user only approves once; Android
            // consent tokens are single-use, but the projection itself can drive
            // any number of capture sessions until it is stopped or revoked.
            val projection = liveProjection ?: run {
                val grantValue = grant ?: throw IllegalStateException("no consent")
                projectionGrant = null
                val manager = getSystemService(
                    android.media.projection.MediaProjectionManager::class.java)
                val fresh = manager.getMediaProjection(grantValue.first, grantValue.second)
                    ?: throw IllegalStateException("projection unavailable")
                fresh.registerCallback(object :
                    android.media.projection.MediaProjection.Callback() {
                    override fun onStop() {
                        Log.i(TAG, "projection revoked")
                        liveProjection = null
                        stopMirroring()
                    }
                }, android.os.Handler(android.os.Looper.getMainLooper()))
                liveProjection = fresh
                fresh
            }

            val bounds = getSystemService(android.view.WindowManager::class.java)
                .maximumWindowMetrics.bounds
            val scale = payload.maxLongEdge.toFloat() /
                maxOf(bounds.width(), bounds.height()).toFloat()
            // Round to even (H.264 needs even dimensions) rather than flooring to
            // a multiple of 16 — that distorted the aspect ratio, and Android
            // letterboxed the mismatch into the frame as black bars.
            fun even(value: Float) = (Math.round(value / 2f) * 2).coerceAtLeast(2)
            val w = even(bounds.width() * scale)
            val h = even(bounds.height() * scale)
            val token = UUID.randomUUID().toString()
            mirrorToken = token
            mirrorWidth = w
            mirrorHeight = h
            pendingMirrorFrames.clear()
            mirrorEncoder = com.akram.ecosystem.features.MirrorEncoder(
                projection, w, h, payload.bitrateBps,
                resources.displayMetrics.densityDpi,
                sink = { type, pts, data -> emitMirrorFrame(type, pts, data) })
            mirrorEncoder?.start()
            sendMessage(Message.MirrorStarted(
                com.akram.ecosystem.core.MirrorStartedPayload(
                    height = h, rotationDeg = 0, token = token, width = w)),
                replyTo = requestId)
        } catch (t: Throwable) {
            Log.e(TAG, "mirror start failed", t)
            stopMirroring()
            sendMessage(Message.Error(ErrorPayload("mirror_error", t.message)),
                replyTo = requestId)
        }
    }

    /** Encoder frames: buffer until the Mac's stream socket attaches, then write. */
    private fun emitMirrorFrame(type: Int, pts: Long, data: ByteArray) {
        val socket = mirrorSocket
        if (socket == null) {
            synchronized(pendingMirrorFrames) {
                // Keep only the newest config + latest frames while waiting.
                if (pendingMirrorFrames.size > 120) pendingMirrorFrames.clear()
                pendingMirrorFrames += Triple(type, pts, data)
            }
            return
        }
        try {
            synchronized(mirrorWriteLock) {
                socket.outputStream.write(BinaryFrames.encode(type, pts, data))
            }
        } catch (t: Throwable) {
            Log.w(TAG, "mirror socket write failed: $t")
            stopMirroring()
        }
    }

    private fun runMirrorStream(socket: SSLSocket) {
        Log.i(TAG, "mirror stream attached")
        synchronized(pendingMirrorFrames) {
            for ((type, pts, data) in pendingMirrorFrames) {
                runCatching {
                    socket.outputStream.write(BinaryFrames.encode(type, pts, data))
                }
            }
            pendingMirrorFrames.clear()
            mirrorSocket = socket
        }
        // Block until the Mac closes the stream (its way of ending the session).
        runCatching { while (socket.inputStream.read() >= 0) Unit }
        if (mirrorSocket === socket) {
            mirrorSocket = null
            pauseMirroring()
        }
    }

    /**
     * Capture only yields frames while the display is awake (Android gives no
     * app-level way to record a powered-off screen), so wake it and hold it on
     * for the session.
     */
    private fun wakeScreenForMirroring() {
        val power = getSystemService(android.os.PowerManager::class.java)
        if (!power.isInteractive) {
            runCatching {
                startActivity(Intent(this, com.akram.ecosystem.ui.WakeActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
        }
        com.akram.ecosystem.accessibility.RemoteInput.setKeepAwake(true)
    }

    // MARK: camera

    private var cameraStreamer: com.akram.ecosystem.features.CameraStreamer? = null
    private var cameraToken: String? = null
    private var cameraRequest: com.akram.ecosystem.core.CameraStartPayload? = null
    @Volatile
    private var cameraSocket: SSLSocket? = null
    private val cameraWriteLock = Any()
    private val pendingCameraFrames = ArrayDeque<Triple<Int, Long, ByteArray>>()

    private fun cameraGranted(): Boolean {
        val granted = checkSelfPermission(android.Manifest.permission.CAMERA) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED
        if (granted && _state.value.cameraPermissionNeeded) {
            _state.value = _state.value.copy(cameraPermissionNeeded = false)
        }
        return granted
    }

    /** The Mac asked for the camera while the app was hidden; retry once visible. */
    private var pendingCameraRequest: Triple<Session, String,
        com.akram.ecosystem.core.CameraStartPayload>? = null

    fun onAppForeground() {
        val pending = pendingCameraRequest ?: return
        pendingCameraRequest = null
        handleCameraStart(pending.first, pending.second, pending.third)
    }

    private fun handleCameraStart(
        session: Session,
        requestId: String,
        payload: com.akram.ecosystem.core.CameraStartPayload,
    ) {
        if (!cameraGranted()) {
            _state.value = _state.value.copy(cameraPermissionNeeded = true)
            bringAppToFront()
            sendMessage(Message.Error(ErrorPayload(
                "camera_permission", "Allow camera access in the Ecosystem app")),
                replyTo = requestId)
            return
        }
        // Android 14+ refuses camera access to a background service: the capture
        // session dies with "Broken pipe". The app has to be on screen, and the
        // service has to carry the camera foreground type.
        if (!MainActivity.isVisible) {
            pendingCameraRequest = Triple(session, requestId, payload)
            bringAppToFront()
            scope.launch {
                kotlinx.coroutines.delay(4000)
                if (pendingCameraRequest?.second == requestId) {
                    pendingCameraRequest = null
                    session.send(Message.Error(ErrorPayload(
                        "camera_foreground", "Open Ecosystem on the phone to start the camera")),
                        replyTo = requestId)
                }
            }
            return
        }
        stopCamera()
        cameraRequest = payload
        try {
            startForeground(
                NOTIFICATION_ID, buildNotification("Camera streaming to your Mac"),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE or
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA)
            val streamer = com.akram.ecosystem.features.CameraStreamer(
                context = this,
                width = payload.width,
                fps = payload.fps,
                bitrateBps = payload.bitrateBps,
                sink = { type, pts, data -> emitCameraFrame(type, pts, data) })
            streamer.start(payload.cameraId, payload.zoom)
            cameraStreamer = streamer
            val token = UUID.randomUUID().toString()
            cameraToken = token
            synchronized(pendingCameraFrames) { pendingCameraFrames.clear() }
            _state.value = _state.value.copy(cameraActive = true)
            updateNotification("Camera streaming to your Mac")
            sendMessage(Message.CameraStarted(
                com.akram.ecosystem.core.CameraStartedPayload(
                    height = streamer.height, rotationDeg = streamer.rotationDeg,
                    token = token, width = payload.width)),
                replyTo = requestId)
        } catch (t: Throwable) {
            Log.e(TAG, "camera start failed", t)
            stopCamera()
            sendMessage(Message.Error(ErrorPayload("camera_error", t.message)),
                replyTo = requestId)
        }
    }

    private fun emitCameraFrame(type: Int, pts: Long, data: ByteArray) {
        val socket = cameraSocket
        if (socket == null) {
            synchronized(pendingCameraFrames) {
                if (pendingCameraFrames.size > 120) pendingCameraFrames.clear()
                pendingCameraFrames += Triple(type, pts, data)
            }
            return
        }
        try {
            synchronized(cameraWriteLock) {
                socket.outputStream.write(BinaryFrames.encode(type, pts, data))
            }
        } catch (t: Throwable) {
            Log.w(TAG, "camera socket write failed: $t")
            stopCamera()
        }
    }

    private fun runCameraStream(socket: SSLSocket) {
        Log.i(TAG, "camera stream attached")
        synchronized(pendingCameraFrames) {
            for ((type, pts, data) in pendingCameraFrames) {
                runCatching { socket.outputStream.write(BinaryFrames.encode(type, pts, data)) }
            }
            pendingCameraFrames.clear()
            cameraSocket = socket
        }
        cameraStreamer?.cachedConfig()?.let {
            emitCameraFrame(BinaryFrames.TYPE_CODEC_CONFIG, 0, it)
        }
        cameraStreamer?.requestKeyframe()
        runCatching { while (socket.inputStream.read() >= 0) Unit }
        if (cameraSocket === socket) {
            cameraSocket = null
            stopCamera()
        }
    }

    private fun bringAppToFront() {
        runCatching {
            startActivity(Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP))
        }
    }

    private fun stopCamera() {
        cameraStreamer?.stop()
        cameraStreamer = null
        cameraToken = null
        runCatching { cameraSocket?.close() }
        cameraSocket = null
        synchronized(pendingCameraFrames) { pendingCameraFrames.clear() }
        if (_state.value.cameraActive) {
            _state.value = _state.value.copy(cameraActive = false)
            // Drop the camera foreground type again.
            startForeground(
                NOTIFICATION_ID,
                buildNotification(_state.value.peerName?.let { "Connected to $it" }
                    ?: "Waiting for your Mac…"),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        }
    }

    /** Detaches the viewer but leaves capture running for an instant re-open. */
    private fun detachMirrorStream() {
        runCatching { mirrorSocket?.close() }
        mirrorSocket = null
        synchronized(pendingMirrorFrames) { pendingMirrorFrames.clear() }
    }

    /**
     * Called when the Mac closes the window. Capture stays alive (reused on the
     * next open, no consent dialog) until it has been idle for a while.
     */
    private fun pauseMirroring() {
        detachMirrorStream()
        mirrorToken = null
        idleMirrorJob?.cancel()
        idleMirrorJob = scope.launch {
            kotlinx.coroutines.delay(MIRROR_IDLE_TIMEOUT_MS)
            if (mirrorSocket == null) {
                Log.i(TAG, "mirror idle; releasing capture")
                stopMirroring()
            }
        }
    }

    private fun stopMirroring() {
        idleMirrorJob?.cancel()
        com.akram.ecosystem.accessibility.RemoteInput.setKeepAwake(false)
        detachMirrorStream()
        mirrorEncoder?.stop()
        mirrorEncoder = null
        mirrorToken = null
        runCatching { liveProjection?.stop() }
        liveProjection = null
        startForeground(
            NOTIFICATION_ID,
            buildNotification(_state.value.peerName?.let { "Connected to $it" }
                ?: "Waiting for your Mac…"),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
    }

    private fun showConsentNotification() {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(
            "ecosystem.consent", "Mirroring requests", NotificationManager.IMPORTANCE_HIGH))
        val open = PendingIntent.getActivity(
            this, 2,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra("requestProjection", true),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        nm.notify(CONSENT_NOTIFICATION_ID, Notification.Builder(this, "ecosystem.consent")
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setContentTitle("Allow screen mirroring?")
            .setContentText("Your Mac wants to view this phone's screen. Tap to allow.")
            .setContentIntent(open)
            .setAutoCancel(true)
            .build())
    }

    // MARK: outbound

    /** Broadcasts to every connected Mac (clipboard, ring, stream frames). */
    fun sendMessage(message: Message, replyTo: String? = null) {
        sessions.values.filter { it.authenticated }.forEach { it.send(message, replyTo) }
    }

    // MARK: plumbing

    private inner class Session(
        val socket: SSLSocket,
        val peerId: String,
        val name: String,
    ) {
        @Volatile
        var authenticated = false
        var authChallenge: ByteArray? = null
        private val writeMutex = Mutex()

        fun send(message: Message, replyTo: String? = null) {
            scope.launch {
                writeMutex.withLock {
                    runCatching {
                        socket.outputStream.write(ProtocolCodec.encodeFrame(
                            id = UUID.randomUUID().toString(),
                            message = message, replyTo = replyTo))
                        socket.outputStream.flush()
                    }.onFailure { Log.w(TAG, "send to $name failed: $it") }
                }
            }
        }

        fun close() = runCatching { socket.close() }
    }

    /**
     * Verifies a Mac against its own stored secret. A Mac paired before multiple
     * Macs were supported has no entry yet, so the single legacy secret is tried
     * once and then recorded under its device id — nobody re-pairs after updating.
     */
    private fun authenticate(session: Session, mac: String) {
        val nonce = session.authChallenge
        if (nonce == null) {
            session.close()
            return
        }
        val candidates = buildList<Pair<ByteArray, Boolean>> {
            PairedPeers.secretFor(filesDir, session.peerId)?.let { add(it to false) }
            PairedPeers.legacySecret(filesDir)?.let { add(it to true) }
        }
        val match = candidates.firstOrNull { (secret, _) ->
            PairingSecret.constantTimeEquals(
                PairingSecret.response(nonce, secret), mac)
        }
        if (match == null) {
            if (PairedPeers.secretFor(filesDir, session.peerId) == null) {
                // A Mac we have never paired with: invite it to pair rather than
                // dropping it, so a second Mac can be added.
                Log.i(TAG, "${session.name} is unknown; offering to pair")
                session.authChallenge = null
                session.send(Message.Error(ErrorPayload(
                    "pair_required", "This Mac is not paired with the phone yet")))
                return
            }
            Log.w(TAG, "auth failed for ${session.name}; closing")
            session.send(Message.Error(ErrorPayload("auth_failed")))
            session.close()
            return
        }
        if (match.second) {
            PairedPeers.add(filesDir, session.peerId, session.name, match.first)
            PairedPeers.retireLegacySecret(filesDir)
            Log.i(TAG, "migrated ${session.name} to per-Mac pairing")
        }
        session.authenticated = true
        session.authChallenge = null
        session.send(Message.AuthOK)
        _state.value = _state.value.copy(paired = true)
        publishConnectionState()
        Log.i(TAG, "${session.name} authenticated")
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
