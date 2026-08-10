package com.akram.ecosystem.accessibility

import android.accessibilityservice.AccessibilityService
import android.content.ClipboardManager
import android.graphics.PixelFormat
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import com.akram.ecosystem.service.ConnectionService

/**
 * Automatic phone→Mac clipboard sync on One UI.
 *
 * Samsung denies clipboard reads to apps that aren't in focus (the stock-Android
 * accessibility exemption is blocked), so this service:
 *  1. Detects a copy by watching SystemUI's "Copied" toast/overlay accessibility
 *     events (SystemUI announces every clipboard change).
 *  2. Briefly attaches an invisible, focusable 1×1 TYPE_ACCESSIBILITY_OVERLAY
 *     window. While it holds window focus this app IS the focused app, making the
 *     clipboard read legal. The window is removed immediately after the read.
 */
class ClipboardAccessibilityService : AccessibilityService() {
    private val handler = Handler(Looper.getMainLooper())
    private var overlay: View? = null
    private var lastAttemptAt = 0L

    // Kept for stock-Android devices where listeners fire normally for a11y apps.
    private var clipboard: ClipboardManager? = null
    private val listener = ClipboardManager.OnPrimaryClipChangedListener {
        Log.i(TAG, "primary clip changed (listener)")
        readAndForward(source = "listener")
    }

    override fun onServiceConnected() {
        Log.i(TAG, "accessibility service connected")
        clipboard = getSystemService(ClipboardManager::class.java).also {
            it.addPrimaryClipChangedListener(listener)
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        event ?: return
        if (event.packageName != "com.android.systemui") return
        val kind = event.eventType
        if (kind != AccessibilityEvent.TYPE_NOTIFICATION_STATE_CHANGED &&
            kind != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED &&
            kind != AccessibilityEvent.TYPE_WINDOWS_CHANGED
        ) return

        // Heuristic: SystemUI toast/overlay right after a copy. Debounce bursts.
        val now = System.currentTimeMillis()
        if (now - lastAttemptAt < 800) return
        lastAttemptAt = now
        Log.i(TAG, "systemui event (${event.eventType}, ${event.className}); trying focused read")
        gainFocusAndRead()
    }

    /** Attach an invisible focusable overlay; read the clipboard once focused. */
    private fun gainFocusAndRead() {
        if (overlay != null) return
        val wm = getSystemService(WindowManager::class.java)
        val view = View(this)
        val params = WindowManager.LayoutParams(
            1, 1,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            // Focusable (no FLAG_NOT_FOCUSABLE) but untouchable and transparent.
            WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSPARENT)
        view.viewTreeObserver.addOnWindowFocusChangeListener { hasFocus ->
            if (hasFocus && overlay === view) {
                readAndForward(source = "overlay")
                removeOverlay()
            }
        }
        overlay = view
        runCatching { wm.addView(view, params) }
            .onFailure { Log.w(TAG, "overlay add failed: $it"); overlay = null }
        // Safety net: never leave the overlay (and its focus steal) behind.
        handler.postDelayed({ removeOverlay() }, 1500)
    }

    private fun removeOverlay() {
        val view = overlay ?: return
        overlay = null
        runCatching { getSystemService(WindowManager::class.java).removeView(view) }
    }

    private fun readAndForward(source: String) {
        val clip = getSystemService(ClipboardManager::class.java).primaryClip
        if (clip == null || clip.itemCount == 0) {
            Log.w(TAG, "[$source] clipboard read returned nothing (blocked?)")
            return
        }
        val text = clip.getItemAt(0).coerceToText(this)?.toString()
            ?.takeIf { it.isNotEmpty() } ?: return
        val service = ConnectionService.instance
        if (service == null) {
            Log.w(TAG, "[$source] ConnectionService not running")
            return
        }
        Log.i(TAG, "[$source] read ok (${text.length} chars); forwarding")
        service.sendLocalClipboard(text)
    }

    override fun onDestroy() {
        clipboard?.removePrimaryClipChangedListener(listener)
        removeOverlay()
        super.onDestroy()
    }

    override fun onInterrupt() = Unit

    private companion object {
        const val TAG = "EcosysClipboard"
    }
}
