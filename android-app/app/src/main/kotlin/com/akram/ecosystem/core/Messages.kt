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
    /** Path relative to the listed/searched folder; absent for direct listings. */
    val relPath: String? = null,
    val size: Long,
)

@Serializable
data class FsSearchPayload(
    /** "image", "video" — matched by file extension. */
    val kinds: List<String>,
    val maxDepth: Int,
    val path: String,
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
data class MirrorStartPayload(
    val bitrateBps: Int,
    val maxLongEdge: Int,
)

@Serializable
data class MirrorStartedPayload(
    val height: Int,
    val rotationDeg: Int,
    val token: String,
    val width: Int,
)

@Serializable
data class MirrorRotatedPayload(
    val height: Int,
    val rotationDeg: Int,
    val width: Int,
)

// Input coordinates are normalized 0..1 relative to the screen, so they're
// independent of resolution and rotation. See docs/protocol.md §12.
@Serializable
data class InputTapPayload(
    val longPress: Boolean = false,
    val x: Double,
    val y: Double,
)

@Serializable
data class InputSwipePayload(
    val durationMs: Int,
    val x1: Double,
    val x2: Double,
    val y1: Double,
    val y2: Double,
)

@Serializable
data class InputKeyPayload(
    /** "back", "home", "recents", "power", "notifications". */
    val key: String,
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
    data class FsSearch(val payload: FsSearchPayload) : Message
    data class FsEntries(val payload: FsEntriesPayload) : Message
    data class FsDownload(val payload: FsDownloadPayload) : Message
    data class FsUpload(val payload: FsUploadPayload) : Message
    data class FsTransferReady(val payload: FsTransferReadyPayload) : Message
    data class FsTransferResult(val payload: FsTransferResultPayload) : Message
    data class FsThumb(val payload: FsThumbPayload) : Message
    data class FsThumbData(val payload: FsThumbDataPayload) : Message
    data class MirrorStart(val payload: MirrorStartPayload) : Message
    data object MirrorNeedsConsent : Message
    data class MirrorStarted(val payload: MirrorStartedPayload) : Message
    data object MirrorStop : Message
    data class MirrorRotated(val payload: MirrorRotatedPayload) : Message
    data class InputTap(val payload: InputTapPayload) : Message
    data class InputSwipe(val payload: InputSwipePayload) : Message
    data class InputKey(val payload: InputKeyPayload) : Message
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
            is FsSearch -> "fs.search"
            is FsEntries -> "fs.entries"
            is FsDownload -> "fs.download"
            is FsUpload -> "fs.upload"
            is FsTransferReady -> "fs.transferReady"
            is FsTransferResult -> "fs.transferResult"
            is FsThumb -> "fs.thumb"
            is FsThumbData -> "fs.thumbData"
            is MirrorStart -> "mirror.start"
            MirrorNeedsConsent -> "mirror.needsConsent"
            is MirrorStarted -> "mirror.started"
            MirrorStop -> "mirror.stop"
            is MirrorRotated -> "mirror.rotated"
            is InputTap -> "input.tap"
            is InputSwipe -> "input.swipe"
            is InputKey -> "input.key"
            is Unknown -> type
        }
}
