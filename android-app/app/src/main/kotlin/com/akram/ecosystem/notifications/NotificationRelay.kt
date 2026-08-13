package com.akram.ecosystem.notifications

import android.app.Notification
import android.app.NotificationManager
import android.app.RemoteInput as AndroidRemoteInput
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import com.akram.ecosystem.core.NotifyActionInfo
import com.akram.ecosystem.core.NotifyPostedPayload
import com.akram.ecosystem.service.ConnectionService

/**
 * Mirrors this phone's notifications to every connected Mac, and presses their
 * buttons when the Mac asks — including filling in inline-reply text. This is
 * the same OS hook desktop-companion apps like KDE Connect use; the user grants
 * it once under Settings → Notification access.
 */
class NotificationRelay : NotificationListenerService() {

    companion object {
        private const val TAG = "NotificationRelay"

        @Volatile
        var instance: NotificationRelay? = null
            private set

        /** Whether the user has granted notification access to this app. */
        fun isEnabled(context: Context): Boolean =
            Settings.Secure.getString(
                context.contentResolver, "enabled_notification_listeners")
                ?.split(":")
                ?.any { it.substringBefore("/") == context.packageName } == true
    }

    /** key → content hash of the last relayed payload, to drop no-op re-posts. */
    private val lastRelayed = HashMap<String, Int>()

    override fun onListenerConnected() {
        instance = this
        Log.i(TAG, "listener connected")
        // The system binds this listener early after boot: a second chance to
        // bring the connection service up if BOOT_COMPLETED was missed/delayed.
        if (ConnectionService.instance == null) ConnectionService.start(this)
    }

    override fun onListenerDisconnected() {
        instance = null
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val payload = describe(sbn)
        if (payload == null) {
            Log.d(TAG, "skipped ${sbn.key}")
            return
        }
        // Apps re-post the same notification constantly (progress ticks, group
        // re-sorts, alert-once refreshes). The phone only buzzes the first
        // time; the Mac should only banner the first time too.
        val signature = payload.copy(whenMs = 0).hashCode()
        synchronized(lastRelayed) {
            if (lastRelayed.put(sbn.key, signature) == signature) {
                Log.d(TAG, "unchanged ${sbn.key}")
                return
            }
        }
        Log.d(TAG, "relaying ${sbn.key}")
        ConnectionService.instance?.notifyPosted(payload)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        synchronized(lastRelayed) { lastRelayed.remove(sbn.key) }
        // Unconditional: telling the Mac about a notification it never showed is
        // a harmless no-op, and cheaper than re-running the filter.
        ConnectionService.instance?.notifyDismissed(sbn.key)
    }

    /** Turns a notification into a wire payload, or null for ones not worth mirroring. */
    private fun describe(sbn: StatusBarNotification): NotifyPostedPayload? {
        val n = sbn.notification
        if (sbn.packageName == packageName) return null
        if (n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return null

        // Ongoing notifications are noise (media players, progress bars, other
        // apps' foreground services) — except incoming calls, which are the
        // single most useful thing to mirror and are always flagged ongoing.
        val isCall = n.category == Notification.CATEGORY_CALL
        if (!sbn.isClearable && !isCall) return null
        if (n.extras.getCharSequence(Notification.EXTRA_TEMPLATE)
                ?.toString()?.contains("MediaStyle") == true) return null

        // Skip silent/minimized channels: if the phone didn't think it was worth
        // a sound or a peek, the Mac shouldn't pop a banner either.
        val ranking = Ranking()
        if (!isCall && currentRanking.getRanking(sbn.key, ranking) &&
            ranking.importance < NotificationManager.IMPORTANCE_DEFAULT) return null

        val title = n.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        val text = (n.extras.getCharSequence(Notification.EXTRA_TEXT)
            ?: n.extras.getCharSequence(Notification.EXTRA_BIG_TEXT))?.toString() ?: ""
        if (title.isEmpty() && text.isEmpty()) return null

        val app = runCatching {
            packageManager.getApplicationLabel(
                packageManager.getApplicationInfo(sbn.packageName, 0)).toString()
        }.getOrDefault(sbn.packageName)

        return NotifyPostedPayload(
            key = sbn.key,
            app = app,
            pkg = sbn.packageName,
            title = title,
            text = text,
            whenMs = n.`when`,
            category = n.category ?: "",
            clearable = sbn.isClearable,
            actions = n.actions.orEmpty().map {
                NotifyActionInfo(
                    title = it.title?.toString() ?: "",
                    reply = !it.remoteInputs.isNullOrEmpty())
            })
    }

    /**
     * Presses button [index] of the notification with [key], on the Mac's behalf.
     * For reply buttons, [reply] is delivered as the typed text.
     */
    fun performAction(key: String, index: Int, reply: String?) {
        val sbn = activeNotifications?.firstOrNull { it.key == key } ?: return
        val action = sbn.notification.actions?.getOrNull(index) ?: return
        try {
            val remoteInputs = action.remoteInputs
            if (reply != null && !remoteInputs.isNullOrEmpty()) {
                val fill = Intent().addFlags(Intent.FLAG_RECEIVER_FOREGROUND)
                val results = Bundle()
                remoteInputs.forEach { results.putCharSequence(it.resultKey, reply) }
                AndroidRemoteInput.addResultsToIntent(remoteInputs, fill, results)
                action.actionIntent.send(this, 0, fill)
            } else {
                action.actionIntent.send()
            }
        } catch (e: Exception) {
            Log.w(TAG, "action '$key'[$index] failed: $e")
            return
        }
        // Answering a call from the Mac: flip to speakerphone so the user can
        // talk without picking the phone up. Best effort — see RemoteInput.
        if (sbn.notification.category == Notification.CATEGORY_CALL) {
            com.akram.ecosystem.accessibility.RemoteInput.tapSpeakerSoon()
        }
    }

    /** Clears the notification with [key] because the Mac dismissed its copy. */
    fun dismiss(key: String) {
        try {
            cancelNotification(key)
        } catch (e: Exception) {
            Log.w(TAG, "dismiss '$key' failed: $e")
        }
    }
}
