package com.akram.ecosystem.core

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer

/**
 * Stream-connection binary framing (docs/protocol.md §2.2):
 * [uint32 BE length][uint8 frameType][int64 BE ptsMicros][payload]
 * where length counts frameType + ptsMicros + payload.
 */
data class BinaryFrame(
    val frameType: Int,
    val ptsMicros: Long,
    val payload: ByteArray,
) {
    override fun equals(other: Any?) = other is BinaryFrame &&
        frameType == other.frameType && ptsMicros == other.ptsMicros &&
        payload.contentEquals(other.payload)

    override fun hashCode() = 31 * (31 * frameType + ptsMicros.hashCode()) +
        payload.contentHashCode()
}

object BinaryFrames {
    const val TYPE_CODEC_CONFIG = 0
    const val TYPE_KEYFRAME = 1
    const val TYPE_DELTA = 2
    const val TYPE_FILE_CHUNK = 3
    const val TYPE_END = 4
    const val TYPE_AUDIO = 5

    const val MAX_FRAME_BYTES = 8 * 1024 * 1024
    const val FILE_CHUNK_BYTES = 256 * 1024

    fun encode(frameType: Int, ptsMicros: Long, payload: ByteArray): ByteArray =
        ByteBuffer.allocate(4 + 1 + 8 + payload.size)
            .putInt(1 + 8 + payload.size)
            .put(frameType.toByte())
            .putLong(ptsMicros)
            .put(payload)
            .array()
}

class BinaryFrameReader {
    class OversizedFrameException(val declared: Int) :
        Exception("declared binary frame length $declared exceeds ${BinaryFrames.MAX_FRAME_BYTES}")

    private var buffer = ByteArrayOutputStream()

    fun append(data: ByteArray): List<BinaryFrame> {
        buffer.write(data)
        val frames = mutableListOf<BinaryFrame>()
        var bytes = buffer.toByteArray()
        while (bytes.size >= 4) {
            val length = ByteBuffer.wrap(bytes, 0, 4).int
            if (length > BinaryFrames.MAX_FRAME_BYTES || length < 9) {
                throw OversizedFrameException(length)
            }
            if (bytes.size < 4 + length) break
            val body = ByteBuffer.wrap(bytes, 4, length)
            frames += BinaryFrame(
                frameType = body.get().toInt() and 0xFF,
                ptsMicros = body.long,
                payload = ByteArray(length - 9).also { body.get(it) })
            bytes = bytes.copyOfRange(4 + length, bytes.size)
        }
        buffer = ByteArrayOutputStream().apply { write(bytes) }
        return frames
    }
}
