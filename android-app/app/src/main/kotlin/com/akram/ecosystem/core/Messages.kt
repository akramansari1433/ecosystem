package com.akram.ecosystem.core

import kotlinx.serialization.Serializable

// Payload types. Fields MUST be declared in alphabetical order: kotlinx.serialization
// emits declaration order, and the canonical encoding requires sorted keys
// (docs/protocol.md §3).

@Serializable
data class HelloPayload(
    val capabilities: List<String>,
    val deviceId: String,
    val name: String,
    val protocolVersion: Int,
)

@Serializable
data class ErrorPayload(
    val code: String,
    val message: String? = null,
)

@Serializable
data class PairRequestPayload(
    val certFingerprint: String,
)

@Serializable
data class PairAbortPayload(
    val reason: String? = null,
)

@Serializable
data class ClipboardSetPayload(
    val text: String,
    val tsMillis: Long,
)

@Serializable
data class StreamAttachPayload(
    val kind: String,
    val token: String,
)

sealed interface Message {
    data class Hello(val payload: HelloPayload) : Message
    data object Ping : Message
    data object Pong : Message
    data class Error(val payload: ErrorPayload) : Message
    data class PairRequest(val payload: PairRequestPayload) : Message
    data object PairAccept : Message
    data object PairReject : Message
    data object PairConfirm : Message
    data class PairAbort(val payload: PairAbortPayload) : Message
    data class ClipboardSet(val payload: ClipboardSetPayload) : Message
    data object RingStart : Message
    data object RingStop : Message
    data object RingStopped : Message
    data class StreamAttach(val payload: StreamAttachPayload) : Message
    data class Unknown(val type: String) : Message

    val typeString: String
        get() = when (this) {
            is Hello -> "hello"
            Ping -> "ping"
            Pong -> "pong"
            is Error -> "error"
            is PairRequest -> "pair.request"
            PairAccept -> "pair.accept"
            PairReject -> "pair.reject"
            PairConfirm -> "pair.confirm"
            is PairAbort -> "pair.abort"
            is ClipboardSet -> "clipboard.set"
            RingStart -> "ring.start"
            RingStop -> "ring.stop"
            RingStopped -> "ring.stopped"
            is StreamAttach -> "stream.attach"
            is Unknown -> type
        }
}
