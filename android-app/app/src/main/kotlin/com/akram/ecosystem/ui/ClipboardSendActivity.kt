package com.akram.ecosystem.ui

import android.app.Activity
import android.content.ClipboardManager
import android.content.Intent
import android.os.Bundle
import android.util.Log
import android.widget.Toast
import com.akram.ecosystem.service.ConnectionService

/**
 * Invisible activity that sends text to the Mac. Two entry points:
 * - Share sheet (ACTION_SEND): sends the shared text directly.
 * - Quick Settings tile: waits for window focus (One UI only allows the focused
 *   app to read the clipboard), reads it, sends, and closes.
 */
class ClipboardSendActivity : Activity() {
    private var handled = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.i(TAG, "onCreate action=${intent?.action} hasText=" +
            "${intent?.hasExtra(Intent.EXTRA_TEXT)}")
        val shared = intent?.takeIf { it.action == Intent.ACTION_SEND }
            ?.getStringExtra(Intent.EXTRA_TEXT)
        if (shared != null) {
            handled = true
            send(shared)
            finish()
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || handled) return
        handled = true
        val clip = getSystemService(ClipboardManager::class.java).primaryClip
        val text = clip?.takeIf { it.itemCount > 0 }
            ?.getItemAt(0)?.coerceToText(this)?.toString()
            ?.takeIf { it.isNotEmpty() }
        if (text == null) {
            Toast.makeText(this, "Clipboard is empty", Toast.LENGTH_SHORT).show()
        } else {
            send(text)
        }
        finish()
    }

    private fun send(text: String) {
        val service = ConnectionService.instance
        if (service == null || !ConnectionService.state.value.connected) {
            Toast.makeText(this, "Not connected to your Mac", Toast.LENGTH_SHORT).show()
            return
        }
        if (service.sendLocalClipboard(text)) {
            Toast.makeText(this, "Sent to Mac", Toast.LENGTH_SHORT).show()
        } else {
            Toast.makeText(this, "Already on your Mac", Toast.LENGTH_SHORT).show()
        }
    }

    private companion object {
        const val TAG = "EcosysClipboard"
    }
}
