package com.akram.ecosystem.accessibility

import android.accessibilityservice.AccessibilityService
import android.os.Handler
import android.os.Looper
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Small helpers that need an AccessibilityService to act on the phone's UI.
 * Wraps the already-enabled clipboard service rather than adding a second
 * permission.
 */
object RemoteInput {
    private val handler = Handler(Looper.getMainLooper())

    @Volatile
    var service: AccessibilityService? = null

    /**
     * After a call is answered from the Mac, click the in-call screen's Speaker
     * button so the user can talk without picking the phone up. Best effort:
     * retries for a few seconds while the in-call UI appears, then gives up
     * silently (e.g. when the Mac pressed Decline and no call screen exists).
     */
    fun tapSpeakerSoon() {
        var attempts = 0
        lateinit var attempt: Runnable
        attempt = Runnable {
            val clicked = clickByLabel("Speaker")
            if (!clicked && ++attempts < 8) handler.postDelayed(attempt, 500)
        }
        handler.postDelayed(attempt, 800)
    }

    private fun clickByLabel(label: String): Boolean {
        val service = service ?: return false
        val roots = (runCatching { service.windows }.getOrNull().orEmpty()
            .mapNotNull { it.root } + listOfNotNull(service.rootInActiveWindow))
        for (root in roots) {
            val matches = root.findAccessibilityNodeInfosByText(label) ?: continue
            for (node in matches) {
                var candidate: AccessibilityNodeInfo? = node
                while (candidate != null && !candidate.isClickable) {
                    candidate = candidate.parent
                }
                if (candidate?.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                    == true) return true
            }
        }
        return false
    }
}
