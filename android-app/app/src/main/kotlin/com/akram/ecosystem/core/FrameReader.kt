package com.akram.ecosystem.core

import java.io.ByteArrayOutputStream

/**
 * Incremental parser for the control-connection framing:
 * [uint32 big-endian length][payload]. See docs/protocol.md §2.1.
 */
class FrameReader {
    companion object {
        const val MAX_FRAME_BYTES = 1_048_576
    }

    class OversizedFrameException(val declared: Int) :
        Exception("declared frame length $declared exceeds $MAX_FRAME_BYTES")

    private var buffer = ByteArrayOutputStream()

    /** Feed received bytes; returns every complete frame payload now available. */
    fun append(data: ByteArray): List<ByteArray> {
        buffer.write(data)
        val frames = mutableListOf<ByteArray>()
        var bytes = buffer.toByteArray()
        while (bytes.size >= 4) {
            val length = ((bytes[0].toInt() and 0xFF) shl 24) or
                ((bytes[1].toInt() and 0xFF) shl 16) or
                ((bytes[2].toInt() and 0xFF) shl 8) or
                (bytes[3].toInt() and 0xFF)
            if (length > MAX_FRAME_BYTES || length < 0) throw OversizedFrameException(length)
            if (bytes.size < 4 + length) break
            frames += bytes.copyOfRange(4, 4 + length)
            bytes = bytes.copyOfRange(4 + length, bytes.size)
        }
        buffer = ByteArrayOutputStream().apply { write(bytes) }
        return frames
    }
}
