package com.akram.ecosystem.features

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import com.akram.ecosystem.core.ClipboardSetPayload
import java.security.MessageDigest

/**
 * Applies remote clipboard updates (background WRITE is allowed on Android 10+)
 * and suppresses echoes. Reading local changes lives in the accessibility service.
 */
class ClipboardHandler(context: Context) {
    private val clipboard = context.getSystemService(ClipboardManager::class.java)

    @Volatile
    private var lastReceivedHash: ByteArray? = null

    @Volatile
    private var lastSentHash: ByteArray? = null

    @Volatile
    private var lastAppliedTs = 0L

    fun applyRemote(payload: ClipboardSetPayload) {
        if (payload.tsMillis < lastAppliedTs) return // last-writer-wins
        lastAppliedTs = payload.tsMillis
        lastReceivedHash = hash(payload.text)
        clipboard.setPrimaryClip(ClipData.newPlainText("Ecosystem", payload.text))
    }

    /**
     * False when [text] is an echo of the Mac's clipboard or a repeat of the last
     * successful send (the auto-sync-on-focus path fires on every app open).
     */
    fun shouldSend(text: String): Boolean {
        val h = hash(text)
        return !h.contentEquals(lastReceivedHash) && !h.contentEquals(lastSentHash)
    }

    /** Record a successful send — only call once the message is actually queued. */
    fun markSent(text: String) {
        lastSentHash = hash(text)
    }

    private fun hash(text: String): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(text.toByteArray())
}
