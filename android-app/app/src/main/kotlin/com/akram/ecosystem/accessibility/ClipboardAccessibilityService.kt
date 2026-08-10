package com.akram.ecosystem.accessibility

import android.accessibilityservice.AccessibilityService
import android.content.ClipboardManager
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
        val clip = clipboard?.primaryClip ?: return@OnPrimaryClipChangedListener
        if (clip.itemCount == 0) return@OnPrimaryClipChangedListener
        val text = clip.getItemAt(0).coerceToText(this)?.toString()
            ?.takeIf { it.isNotEmpty() } ?: return@OnPrimaryClipChangedListener
        ConnectionService.instance?.sendLocalClipboard(text)
    }

    override fun onServiceConnected() {
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
}
