package com.akram.ecosystem.accessibility

import android.accessibilityservice.AccessibilityService
import android.content.ClipboardManager
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import com.akram.ecosystem.service.ConnectionService

/**
 * Enabling this service exempts the app from the Android 10+ background
 * clipboard-read restriction, letting phone→Mac clipboard sync work from any app.
 * It reads nothing else and handles no accessibility events.
 */
class ClipboardAccessibilityService : AccessibilityService() {
    private var clipboard: ClipboardManager? = null

    private val listener = ClipboardManager.OnPrimaryClipChangedListener {
        Log.i(TAG, "primary clip changed")
        val clip = clipboard?.primaryClip
        if (clip == null) {
            Log.w(TAG, "primaryClip is null (read blocked?)")
            return@OnPrimaryClipChangedListener
        }
        if (clip.itemCount == 0) {
            Log.w(TAG, "clip has no items")
            return@OnPrimaryClipChangedListener
        }
        val text = clip.getItemAt(0).coerceToText(this)?.toString()
            ?.takeIf { it.isNotEmpty() }
        if (text == null) {
            Log.w(TAG, "clip item not coercible to text")
            return@OnPrimaryClipChangedListener
        }
        val service = ConnectionService.instance
        if (service == null) {
            Log.w(TAG, "ConnectionService not running; dropping clip")
            return@OnPrimaryClipChangedListener
        }
        Log.i(TAG, "forwarding clip (${text.length} chars)")
        service.sendLocalClipboard(text)
    }

    override fun onServiceConnected() {
        Log.i(TAG, "accessibility service connected")
        clipboard = getSystemService(ClipboardManager::class.java).also {
            it.addPrimaryClipChangedListener(listener)
        }
    }

    override fun onDestroy() {
        clipboard?.removePrimaryClipChangedListener(listener)
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit
    override fun onInterrupt() = Unit

    private companion object {
        const val TAG = "EcosysClipboard"
    }
}
