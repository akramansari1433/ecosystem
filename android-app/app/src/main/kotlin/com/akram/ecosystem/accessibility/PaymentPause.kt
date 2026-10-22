package com.akram.ecosystem.accessibility

import android.accessibilityservice.AccessibilityService
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log

/**
 * Payment and banking apps treat any enabled third-party accessibility service
 * as a fraud risk — fair enough, since one can read screens and press buttons —
 * and warn or refuse to run while ours is on. Their check is simply "is the
 * service enabled", so the fix is to not be enabled while they're on screen:
 * the service switches itself off the moment a payment app comes to the
 * foreground, and comes back the moment the payment app leaves the screen
 * (watched through UsageStatsManager, since the usual watcher — the service
 * itself — is off). Opening Ecosystem, locking the screen, or
 * [RESUME_AFTER_MS] passing also resume it, as backstops.
 *
 * Turning an accessibility service back ON programmatically needs
 * WRITE_SECURE_SETTINGS, which Android only hands out over ADB:
 * `adb shell pm grant com.akram.ecosystem android.permission.WRITE_SECURE_SETTINGS`.
 * Without it the pause still happens, and the notification offers the settings
 * shortcut to re-enable by hand.
 */
object PaymentPause {
    private const val TAG = "PaymentPause"
    private const val CHANNEL_ID = "ecosystem.pause"
    private const val NOTIFICATION_ID = 4
    private const val RESUME_AFTER_MS = 10 * 60 * 1000L

    private const val SERVICE_COMPONENT =
        "com.akram.ecosystem/com.akram.ecosystem.accessibility.ClipboardAccessibilityService"

    /** Apps that are known to complain. Android has no "finance" app category
     *  to query, so this is an explicit list — extending it is one line. */
    private val knownPackages = setOf(
        "com.google.android.apps.nbu.paisa.user",   // Google Pay
        "com.phonepe.app",
        "net.one97.paytm",
        "in.org.npci.upiapp",                       // BHIM
        "com.samsung.android.spay",
        "com.samsung.android.spaylite",
        "com.dreamplug.androidapp",                 // CRED
        "com.csam.icici.bank.imobile",
        "com.snapwork.hdfc",
        "com.sbi.lotusintouch",
        "com.axis.mobile",
        "com.msf.kbank.mobile",
        "com.paypal.android.p2pmobile",
        "com.mobikwik_new",
    )

    private const val POLL_MS = 2_500L
    private const val PREFS = "payment_pause"

    private val handler = Handler(Looper.getMainLooper())
    private var screenOffReceiver: BroadcastReceiver? = null

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun isPaymentApp(context: Context, pkg: String): Boolean = pkg in knownPackages

    fun canAutoResume(context: Context): Boolean =
        context.checkSelfPermission(android.Manifest.permission.WRITE_SECURE_SETTINGS) ==
            PackageManager.PERMISSION_GRANTED

    /** Switches the service off and arranges for it to come back. */
    fun pause(service: AccessibilityService, foregroundPkg: String) {
        val context = service.applicationContext
        val appName = runCatching {
            context.packageManager.getApplicationLabel(
                context.packageManager.getApplicationInfo(foregroundPkg, 0)).toString()
        }.getOrDefault("a payment app")
        Log.i(TAG, "pausing for $foregroundPkg")

        val auto = canAutoResume(context)
        notify(context, auto, appName)
        if (auto) {
            prefs(context).edit().putLong("pausedAt", System.currentTimeMillis()).apply()
            arm(context)
        }
        // Last: after disableSelf() this service instance is dead.
        service.disableSelf()
    }

    /** Sets up every way back: leaving the app, locking, the time cap. */
    private fun arm(context: Context) {
        handler.removeCallbacksAndMessages(null)
        handler.postDelayed({ resume(context) }, RESUME_AFTER_MS)
        watchForScreenOff(context)
        pollForeground(context, awayStreak = 0)
    }

    /**
     * ConnectionService calls this on every start: if the process died while
     * paused, the watchers above died with it — re-arm or catch up.
     */
    fun restoreAfterRestart(context: Context) {
        val pausedAt = prefs(context).getLong("pausedAt", 0)
        if (pausedAt == 0L || !canAutoResume(context)) return
        if (System.currentTimeMillis() - pausedAt > RESUME_AFTER_MS) {
            resume(context)
        } else {
            arm(context)
        }
    }

    /** Opening the Ecosystem app itself is a clear "I'm done paying". */
    fun resumeIfPaused(context: Context) {
        if (prefs(context).getLong("pausedAt", 0) != 0L) resume(context)
    }

    /**
     * Watches what's on screen while paused — every few seconds, resume unless
     * a payment app is still up. Two consecutive sightings guard against the
     * brief launcher flash of app switching. Needs usage access
     * (`adb shell appops set com.akram.ecosystem GET_USAGE_STATS allow`);
     * without it the poll sees nothing and the other triggers carry the load.
     */
    private fun pollForeground(context: Context, awayStreak: Int) {
        handler.postDelayed({
            val pkg = foregroundPackage(context)
            val away = pkg != null && !isPaymentApp(context, pkg)
            val streak = if (away) awayStreak + 1 else 0
            if (streak >= 2) resume(context) else pollForeground(context, streak)
        }, POLL_MS)
    }

    private fun foregroundPackage(context: Context): String? {
        val usm = context.getSystemService(UsageStatsManager::class.java)
        val now = System.currentTimeMillis()
        val events = usm.queryEvents(now - 60_000, now)
        var latest: String? = null
        val event = UsageEvents.Event()
        while (events.hasNextEvent()) {
            events.getNextEvent(event)
            if (event.eventType == UsageEvents.Event.ACTIVITY_RESUMED) {
                latest = event.packageName
            }
        }
        return latest
    }

    /** Re-adds the service to the enabled list; a no-op without the grant. */
    fun resume(context: Context) {
        handler.removeCallbacksAndMessages(null)
        screenOffReceiver?.let { runCatching { context.unregisterReceiver(it) } }
        screenOffReceiver = null
        prefs(context).edit().remove("pausedAt").apply()
        if (!canAutoResume(context)) return
        runCatching {
            val current = Settings.Secure.getString(
                context.contentResolver, "enabled_accessibility_services").orEmpty()
            val others = current.split(":")
                .filter { it.isNotEmpty() && it != SERVICE_COMPONENT }
            // Write without us, then with us: if One UI left the stale entry in
            // place after disableSelf(), an identical value would change nothing
            // and the service would stay dead. The toggle forces a re-bind.
            Settings.Secure.putString(
                context.contentResolver, "enabled_accessibility_services",
                others.joinToString(":"))
            Settings.Secure.putString(
                context.contentResolver, "enabled_accessibility_services",
                (others + SERVICE_COMPONENT).joinToString(":"))
            Settings.Secure.putInt(context.contentResolver, "accessibility_enabled", 1)
            context.getSystemService(NotificationManager::class.java)
                .cancel(NOTIFICATION_ID)
            Log.i(TAG, "resumed")
        }.onFailure { Log.w(TAG, "resume failed: $it") }
    }

    /** The screen locking means the payment is over; come back early. */
    private fun watchForScreenOff(context: Context) {
        if (screenOffReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(receiverContext: Context, intent: Intent) {
                resume(receiverContext.applicationContext)
            }
        }
        screenOffReceiver = receiver
        context.registerReceiver(receiver, IntentFilter(Intent.ACTION_SCREEN_OFF))
    }

    private fun notify(context: Context, auto: Boolean, appName: String) {
        val nm = context.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(
            CHANNEL_ID, "Paused for payment apps", NotificationManager.IMPORTANCE_LOW))
        val builder = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_lock_idle_lock)
            .setContentTitle("Clipboard sync paused")
        if (auto) {
            builder.setContentText(
                "$appName doesn't allow accessibility services. " +
                    "Sync returns when you leave the app.")
        } else {
            builder.setContentText(
                "$appName doesn't allow accessibility services. " +
                    "Tap to turn Ecosystem back on when you're done.")
                .setContentIntent(PendingIntent.getActivity(
                    context, 4,
                    Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    PendingIntent.FLAG_IMMUTABLE))
        }
        nm.notify(NOTIFICATION_ID, builder.setAutoCancel(true).build())
    }
}
