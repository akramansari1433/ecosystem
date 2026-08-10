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

@Serializable
data class FsEntry(
    val isDir: Boolean,
    val mtimeMillis: Long,
    val name: String,
    val size: Long,
)

@Serializable
data class FsListPayload(
    val path: String,
)

@Serializable
data class FsEntriesPayload(
    val entries: List<FsEntry>,
)

@Serializable
data class FsDownloadPayload(
    val path: String,
)

@Serializable
data class FsUploadPayload(
    val destPath: String,
    val size: Long,
)

@Serializable
data class FsTransferReadyPayload(
    val size: Long? = null,
    val token: String,
)

@Serializable
data class FsThumbPayload(
    val maxEdge: Int,
    val path: String,
)

@Serializable
data class FsThumbDataPayload(
    val dataBase64: String? = null,
)

@Serializable
data class FsTransferResultPayload(
    val message: String? = null,
    val ok: Boolean,
    val sha256: String? = null,
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
    data class FsList(val payload: FsListPayload) : Message
    data class FsEntries(val payload: FsEntriesPayload) : Message
    data class FsDownload(val payload: FsDownloadPayload) : Message
    data class FsUpload(val payload: FsUploadPayload) : Message
    data class FsTransferReady(val payload: FsTransferReadyPayload) : Message
    data class FsTransferResult(val payload: FsTransferResultPayload) : Message
    data class FsThumb(val payload: FsThumbPayload) : Message
    data class FsThumbData(val payload: FsThumbDataPayload) : Message
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
            is FsList -> "fs.list"
            is FsEntries -> "fs.entries"
            is FsDownload -> "fs.download"
            is FsUpload -> "fs.upload"
            is FsTransferReady -> "fs.transferReady"
            is FsTransferResult -> "fs.transferResult"
            is FsThumb -> "fs.thumb"
            is FsThumbData -> "fs.thumbData"
            is Unknown -> type
        }
}
