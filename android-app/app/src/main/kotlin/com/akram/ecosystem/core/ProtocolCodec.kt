package com.akram.ecosystem.core

import java.nio.ByteBuffer
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement

data class InboundEnvelope(
    val id: String,
    val replyTo: String?,
    val message: Message,
)

object ProtocolCodec {
    class MissingPayloadException(type: String) :
        Exception("message type '$type' requires a payload")

    // Canonical form per docs/protocol.md §3: compact, no explicit nulls;
    // key order comes from alphabetical field declaration in the data classes.
    private val json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
    }

    @Serializable
    private data class RawEnvelope(
        val id: String,
        val payload: JsonElement? = null,
        val replyTo: String? = null,
        val type: String,
    )

    /** Encodes a complete wire frame: 4-byte BE length prefix + canonical JSON. */
    fun encodeFrame(id: String, message: Message, replyTo: String? = null): ByteArray {
        val payload: JsonElement? = when (message) {
            is Message.Hello -> json.encodeToJsonElement(message.payload)
            is Message.Error -> json.encodeToJsonElement(message.payload)
            is Message.PairRequest -> json.encodeToJsonElement(message.payload)
            is Message.PairAbort -> json.encodeToJsonElement(message.payload)
            is Message.ClipboardSet -> json.encodeToJsonElement(message.payload)
            is Message.StreamAttach -> json.encodeToJsonElement(message.payload)
            is Message.FsList -> json.encodeToJsonElement(message.payload)
            is Message.FsSearch -> json.encodeToJsonElement(message.payload)
            is Message.FsEntries -> json.encodeToJsonElement(message.payload)
            is Message.FsDownload -> json.encodeToJsonElement(message.payload)
            is Message.FsUpload -> json.encodeToJsonElement(message.payload)
            is Message.FsTransferReady -> json.encodeToJsonElement(message.payload)
            is Message.FsTransferResult -> json.encodeToJsonElement(message.payload)
            is Message.FsThumb -> json.encodeToJsonElement(message.payload)
            is Message.FsThumbData -> json.encodeToJsonElement(message.payload)
            is Message.MirrorStart -> json.encodeToJsonElement(message.payload)
            is Message.MirrorStarted -> json.encodeToJsonElement(message.payload)
            is Message.InputTap -> json.encodeToJsonElement(message.payload)
            is Message.InputSwipe -> json.encodeToJsonElement(message.payload)
            is Message.InputKey -> json.encodeToJsonElement(message.payload)
            is Message.InputText -> json.encodeToJsonElement(message.payload)
            is Message.InputScroll -> json.encodeToJsonElement(message.payload)
            is Message.CameraStart -> json.encodeToJsonElement(message.payload)
            is Message.CameraStarted -> json.encodeToJsonElement(message.payload)
            is Message.CameraSwitchLens -> json.encodeToJsonElement(message.payload)
            is Message.AuthChallenge -> json.encodeToJsonElement(message.payload)
            is Message.AuthResponse -> json.encodeToJsonElement(message.payload)
            else -> null
        }
        val body = json.encodeToString(
            RawEnvelope.serializer(),
            RawEnvelope(id = id, payload = payload, replyTo = replyTo, type = message.typeString),
        ).toByteArray(Charsets.UTF_8)
        return ByteBuffer.allocate(4 + body.size).putInt(body.size).put(body).array()
    }

    /** Decodes one JSON frame payload (without the length prefix). */
    fun decodeFrame(bytes: ByteArray): InboundEnvelope {
        val raw = json.decodeFromString(
            RawEnvelope.serializer(), bytes.toString(Charsets.UTF_8))
        val message = when (raw.type) {
            "hello" -> Message.Hello(payload(raw))
            "ping" -> Message.Ping
            "pong" -> Message.Pong
            "error" -> Message.Error(payload(raw))
            "pair.request" -> Message.PairRequest(payload(raw))
            "pair.accept" -> Message.PairAccept
            "pair.reject" -> Message.PairReject
            "pair.confirm" -> Message.PairConfirm
            "pair.abort" -> Message.PairAbort(payload(raw))
            "clipboard.set" -> Message.ClipboardSet(payload(raw))
            "ring.start" -> Message.RingStart
            "ring.stop" -> Message.RingStop
            "ring.stopped" -> Message.RingStopped
            "stream.attach" -> Message.StreamAttach(payload(raw))
            "fs.list" -> Message.FsList(payload(raw))
            "fs.search" -> Message.FsSearch(payload(raw))
            "fs.entries" -> Message.FsEntries(payload(raw))
            "fs.download" -> Message.FsDownload(payload(raw))
            "fs.upload" -> Message.FsUpload(payload(raw))
            "fs.transferReady" -> Message.FsTransferReady(payload(raw))
            "fs.transferResult" -> Message.FsTransferResult(payload(raw))
            "fs.thumb" -> Message.FsThumb(payload(raw))
            "fs.thumbData" -> Message.FsThumbData(payload(raw))
            "mirror.start" -> Message.MirrorStart(payload(raw))
            "mirror.needsConsent" -> Message.MirrorNeedsConsent
            "mirror.started" -> Message.MirrorStarted(payload(raw))
            "mirror.stop" -> Message.MirrorStop
            "input.tap" -> Message.InputTap(payload(raw))
            "input.swipe" -> Message.InputSwipe(payload(raw))
            "input.key" -> Message.InputKey(payload(raw))
            "input.text" -> Message.InputText(payload(raw))
            "input.scroll" -> Message.InputScroll(payload(raw))
            "camera.start" -> Message.CameraStart(payload(raw))
            "camera.started" -> Message.CameraStarted(payload(raw))
            "camera.switchLens" -> Message.CameraSwitchLens(payload(raw))
            "camera.stop" -> Message.CameraStop
            "auth.challenge" -> Message.AuthChallenge(payload(raw))
            "auth.response" -> Message.AuthResponse(payload(raw))
            "auth.ok" -> Message.AuthOK
            else -> Message.Unknown(raw.type)
        }
        return InboundEnvelope(id = raw.id, replyTo = raw.replyTo, message = message)
    }

    private inline fun <reified P> payload(raw: RawEnvelope): P {
        val element = raw.payload ?: throw MissingPayloadException(raw.type)
        return json.decodeFromJsonElement<P>(element)
    }
}
