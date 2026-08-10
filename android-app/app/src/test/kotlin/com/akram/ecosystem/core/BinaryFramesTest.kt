package com.akram.ecosystem.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class BinaryFramesTest {
    private val cases = Json.parseToJsonElement(
        TestVectors.file("binary-frames.json").readText())
        .jsonObject["cases"]!!.jsonArray.map { it.jsonObject }

    @Test
    fun encodesEveryFixtureByteExactly() {
        for (case in cases) {
            val name = case["name"]!!.jsonPrimitive.content
            val frame = BinaryFrames.encode(
                frameType = case["frameType"]!!.jsonPrimitive.content.toInt(),
                ptsMicros = case["ptsMicros"]!!.jsonPrimitive.content.toLong(),
                payload = case["payloadHex"]!!.jsonPrimitive.content.hexBytes())
            assertEquals("case $name", case["framedHex"]!!.jsonPrimitive.content, frame.toHex())
        }
    }

    @Test
    fun readerDecodesEveryFixtureFromByteDribble() {
        val reader = BinaryFrameReader()
        val decoded = mutableListOf<BinaryFrame>()
        for (case in cases) {
            for (b in case["framedHex"]!!.jsonPrimitive.content.hexBytes()) {
                decoded += reader.append(byteArrayOf(b))
            }
        }
        assertEquals(cases.size, decoded.size)
        for ((case, frame) in cases.zip(decoded)) {
            val name = case["name"]!!.jsonPrimitive.content
            assertEquals("case $name", case["frameType"]!!.jsonPrimitive.content.toInt(), frame.frameType)
            assertEquals("case $name", case["ptsMicros"]!!.jsonPrimitive.content.toLong(), frame.ptsMicros)
            assertArrayEquals("case $name", case["payloadHex"]!!.jsonPrimitive.content.hexBytes(), frame.payload)
        }
    }
}
