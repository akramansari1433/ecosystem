package com.akram.ecosystem.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingCodeTest {
    @Test
    fun derivesEveryFixtureCode() {
        val cases = Json.parseToJsonElement(TestVectors.file("pairing-codes.json").readText())
            .jsonObject["cases"]!!.jsonArray.map { it.jsonObject }
        assertTrue(cases.isNotEmpty())
        for (case in cases) {
            val name = case["name"]!!.jsonPrimitive.content
            val derA = case["derAHex"]!!.jsonPrimitive.content.hexBytes()
            val derB = case["derBHex"]!!.jsonPrimitive.content.hexBytes()
            val expected = case["expectedCode"]!!.jsonPrimitive.content
            assertEquals("case $name", expected, PairingCode.derive(derA, derB))
            assertEquals("case $name swapped", expected, PairingCode.derive(derB, derA))
        }
    }

    @Test
    fun alwaysSixDigits() {
        val code = PairingCode.derive(byteArrayOf(0x01), byteArrayOf(0x02))
        assertEquals(6, code.length)
        assertTrue(code.all { it.isDigit() })
    }

    @Test
    fun unsignedByteComparison() {
        // 0x80 (-128 as signed byte) must sort AFTER 0x7f, not before.
        val low = byteArrayOf(0x7f)
        val high = byteArrayOf(0x80.toByte())
        assertEquals(PairingCode.derive(low, high), PairingCode.derive(high, low))
    }
}
