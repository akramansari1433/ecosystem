package com.akram.ecosystem.core

import java.nio.ByteBuffer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

private fun framed(payload: ByteArray): ByteArray =
    ByteBuffer.allocate(4 + payload.size).putInt(payload.size).put(payload).array()

class FrameReaderTest {
    @Test
    fun singleFrame() {
        val reader = FrameReader()
        val payload = """{"type":"ping"}""".toByteArray()
        val frames = reader.append(framed(payload))
        assertEquals(1, frames.size)
        assertArrayEquals(payload, frames[0])
    }

    @Test
    fun frameSplitByteByByte() {
        val reader = FrameReader()
        val payload = """{"type":"pong"}""".toByteArray()
        val wire = framed(payload)
        val collected = mutableListOf<ByteArray>()
        for (b in wire) collected += reader.append(byteArrayOf(b))
        assertEquals(1, collected.size)
        assertArrayEquals(payload, collected[0])
    }

    @Test
    fun twoFramesCoalesced() {
        val reader = FrameReader()
        val a = """{"n":1}""".toByteArray()
        val b = """{"n":2}""".toByteArray()
        val frames = reader.append(framed(a) + framed(b))
        assertEquals(2, frames.size)
        assertArrayEquals(a, frames[0])
        assertArrayEquals(b, frames[1])
    }

    @Test
    fun oversizedFrameThrows() {
        val reader = FrameReader()
        val header = ByteBuffer.allocate(4).putInt(FrameReader.MAX_FRAME_BYTES + 1).array()
        val ex = assertThrows(FrameReader.OversizedFrameException::class.java) {
            reader.append(header)
        }
        assertTrue(ex.declared > FrameReader.MAX_FRAME_BYTES)
    }
}
