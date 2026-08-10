package com.akram.ecosystem.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

private val expectedMessages: Map<String, Triple<String, String?, Message>> = mapOf(
    "hello" to Triple(
        "00000000-0000-4000-8000-000000000001", null,
        Message.Hello(HelloPayload(
            capabilities = listOf("clipboard", "ring"),
            deviceId = "11111111-2222-4333-8444-555555555555",
            name = "Akram's Mac", protocolVersion = 1))),
    "ping" to Triple("00000000-0000-4000-8000-000000000002", null, Message.Ping),
    "pong-reply" to Triple(
        "00000000-0000-4000-8000-000000000003",
        "00000000-0000-4000-8000-000000000002", Message.Pong),
    "pair.request" to Triple(
        "00000000-0000-4000-8000-000000000004", null,
        Message.PairRequest(PairRequestPayload("a".repeat(64)))),
    "pair.confirm" to Triple("00000000-0000-4000-8000-000000000005", null, Message.PairConfirm),
    "clipboard.set" to Triple(
        "00000000-0000-4000-8000-000000000006", null,
        Message.ClipboardSet(ClipboardSetPayload(text = "héllo wörld 👋", tsMillis = 1_754_870_400_000L))),
    "ring.start" to Triple("00000000-0000-4000-8000-000000000007", null, Message.RingStart),
    "error" to Triple(
        "00000000-0000-4000-8000-000000000008", null,
        Message.Error(ErrorPayload(code = "version_mismatch"))),
    "stream.attach" to Triple(
        "00000000-0000-4000-8000-000000000009", null,
        Message.StreamAttach(StreamAttachPayload(kind = "file", token = "tok-123"))),
)

class ProtocolCodecTest {
    private val fixtures = Json.parseToJsonElement(TestVectors.file("envelope.json").readText())
        .jsonObject["cases"]!!.jsonArray.map { it.jsonObject }

    @Test
    fun encodesEveryFixtureByteExactly() {
        for (case in fixtures) {
            val name = case["name"]!!.jsonPrimitive.content
            val (id, replyTo, message) = expectedMessages.getValue(name)
            val framed = ProtocolCodec.encodeFrame(id = id, message = message, replyTo = replyTo)
            assertEquals("case $name", case["framedHex"]!!.jsonPrimitive.content, framed.toHex())
        }
    }

    @Test
    fun decodesEveryFixture() {
        for (case in fixtures) {
            val name = case["name"]!!.jsonPrimitive.content
            val (id, replyTo, message) = expectedMessages.getValue(name)
            val inbound = ProtocolCodec.decodeFrame(
                case["json"]!!.jsonPrimitive.content.toByteArray())
            assertEquals("case $name", id, inbound.id)
            assertEquals("case $name", replyTo, inbound.replyTo)
            assertEquals("case $name", message, inbound.message)
        }
    }

    @Test
    fun unknownTypeDecodesToUnknown() {
        val inbound = ProtocolCodec.decodeFrame(
            """{"id":"x","type":"future.thing"}""".toByteArray())
        assertEquals(Message.Unknown("future.thing"), inbound.message)
    }

    @Test
    fun missingPayloadForTypedMessageThrows() {
        assertThrows(ProtocolCodec.MissingPayloadException::class.java) {
            ProtocolCodec.decodeFrame("""{"id":"x","type":"clipboard.set"}""".toByteArray())
        }
    }
}
