package com.akram.ecosystem.accessibility

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * Injects touch gestures and navigation actions on behalf of the Mac.
 *
 * Gesture dispatch is only available to an AccessibilityService, so this wraps
 * the already-enabled clipboard service rather than adding a second permission.
 */
object RemoteInput {
    private const val TAG = "EcosysInput"
    private val handler = Handler(Looper.getMainLooper())

    @Volatile
    var service: AccessibilityService? = null

    val isAvailable: Boolean get() = service != null

    fun tap(x: Float, y: Float, longPress: Boolean) {
        val path = Path().apply { moveTo(x, y) }
        dispatch(path, if (longPress) 600L else 40L)
    }

    fun swipe(x1: Float, y1: Float, x2: Float, y2: Float, durationMs: Long) {
        val path = Path().apply {
            moveTo(x1, y1)
            lineTo(x2, y2)
        }
        dispatch(path, durationMs.coerceIn(30L, 3_000L))
    }

    fun globalAction(key: String): Boolean {
        val service = service ?: return false
        val action = when (key) {
            "back" -> AccessibilityService.GLOBAL_ACTION_BACK
            "home" -> AccessibilityService.GLOBAL_ACTION_HOME
            "recents" -> AccessibilityService.GLOBAL_ACTION_RECENTS
            "notifications" -> AccessibilityService.GLOBAL_ACTION_NOTIFICATIONS
            "lock" -> AccessibilityService.GLOBAL_ACTION_LOCK_SCREEN
            else -> return false
        }
        var performed = false
        handler.post { performed = service.performGlobalAction(action) }
        return true.also { Log.i(TAG, "global action $key (queued=$performed)") }
    }

    private fun dispatch(path: Path, durationMs: Long) {
        val service = service ?: run {
            Log.w(TAG, "no accessibility service; cannot inject touch")
            return
        }
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, durationMs))
            .build()
        handler.post {
            runCatching { service.dispatchGesture(gesture, null, null) }
                .onFailure { Log.w(TAG, "dispatchGesture failed: $it") }
        }
    }
}
