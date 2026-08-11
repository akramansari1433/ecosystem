import Foundation

// Payload types. Property names must match docs/protocol.md exactly;
// canonical encoding sorts keys, so declaration order is free.

struct HelloPayload: Codable, Equatable {
    let capabilities: [String]
    let deviceId: String
    let name: String
    let protocolVersion: Int
}

struct ErrorPayload: Codable, Equatable {
    let code: String
    let message: String?
}

struct PairRequestPayload: Codable, Equatable {
    let certFingerprint: String
}

struct PairAbortPayload: Codable, Equatable {
    let reason: String?
}

struct ClipboardSetPayload: Codable, Equatable {
    let text: String
    let tsMillis: Int64
}

struct StreamAttachPayload: Codable, Equatable {
    let kind: String
    let token: String
}

struct FsEntry: Codable, Equatable, Hashable {
    let isDir: Bool
    let mtimeMillis: Int64
    let name: String
    /// Path relative to the listed/searched folder; absent for direct listings.
    var relPath: String?
    let size: Int64
}

struct FsListPayload: Codable, Equatable {
    let path: String
}

struct FsSearchPayload: Codable, Equatable {
    let kinds: [String]
    let maxDepth: Int
    let path: String
}

struct FsEntriesPayload: Codable, Equatable {
    let entries: [FsEntry]
}

struct FsDownloadPayload: Codable, Equatable {
    let path: String
}

struct FsUploadPayload: Codable, Equatable {
    let destPath: String
    let size: Int64
}

struct FsTransferReadyPayload: Codable, Equatable {
    let size: Int64?
    let token: String
}

struct FsThumbPayload: Codable, Equatable {
    let maxEdge: Int
    let path: String
}

struct FsThumbDataPayload: Codable, Equatable {
    let dataBase64: String?
}

struct MirrorStartPayload: Codable, Equatable {
    let bitrateBps: Int
    let maxLongEdge: Int
}

struct MirrorStartedPayload: Codable, Equatable {
    let height: Int
    let rotationDeg: Int
    let token: String
    let width: Int
}

struct CameraDeviceInfo: Codable, Equatable, Hashable, Identifiable {
    /// "back" or "front".
    let facing: String
    let id: String
    /// Human label, e.g. "Ultra wide".
    let label: String
    /// Telephoto lenses are reached by zooming, not by opening another camera.
    /// Optional because the phone omits values equal to their default.
    let maxZoom: Float?
    let minZoom: Float?

    var zoomCeiling: Float { maxZoom ?? 1 }
}

struct CameraZoomPayload: Codable, Equatable {
    let ratio: Float
}

struct CameraListPayload: Codable, Equatable {
    let cameras: [CameraDeviceInfo]
}

struct CameraStartPayload: Codable, Equatable {
    let bitrateBps: Int
    /// Camera id from camera.cameras; empty means "first back camera".
    let cameraId: String
    let fps: Int
    let width: Int
}

struct CameraStartedPayload: Codable, Equatable {
    let height: Int
    /// Degrees to rotate the picture: camera sensors are mounted sideways.
    /// Absent when zero, since the phone omits defaults.
    let rotationDeg: Int?
    let token: String
    let width: Int
}

struct AuthChallengePayload: Codable, Equatable {
    let nonce: String
}

struct AuthResponsePayload: Codable, Equatable {
    let mac: String
}

struct InputTapPayload: Codable, Equatable {
    let longPress: Bool
    let x: Double
    let y: Double
}

struct InputSwipePayload: Codable, Equatable {
    let durationMs: Int
    let x1: Double
    let x2: Double
    let y1: Double
    let y2: Double
}

struct InputKeyPayload: Codable, Equatable {
    let key: String
}

struct InputTextPayload: Codable, Equatable {
    let text: String
}

struct InputScrollPayload: Codable, Equatable {
    /// "begin", "move" or "end" — one continuous drag on the phone.
    let phase: String
    let x: Double
    let y: Double
}

struct FsTransferResultPayload: Codable, Equatable {
    let message: String?
    let ok: Bool
    let sha256: String?
    let token: String
}

enum Message: Equatable {
    case hello(HelloPayload)
    case ping
    case pong
    case error(ErrorPayload)
    case pairRequest(PairRequestPayload)
    case pairAccept
    case pairReject
    case pairConfirm
    case pairAbort(PairAbortPayload)
    case clipboardSet(ClipboardSetPayload)
    case ringStart
    case ringStop
    case ringStopped
    case streamAttach(StreamAttachPayload)
    case fsList(FsListPayload)
    case fsSearch(FsSearchPayload)
    case fsEntries(FsEntriesPayload)
    case fsDownload(FsDownloadPayload)
    case fsUpload(FsUploadPayload)
    case fsTransferReady(FsTransferReadyPayload)
    case fsTransferResult(FsTransferResultPayload)
    case fsThumb(FsThumbPayload)
    case fsThumbData(FsThumbDataPayload)
    case mirrorStart(MirrorStartPayload)
    case mirrorNeedsConsent
    case mirrorStarted(MirrorStartedPayload)
    case mirrorStop
    case inputTap(InputTapPayload)
    case inputSwipe(InputSwipePayload)
    case inputKey(InputKeyPayload)
    case inputText(InputTextPayload)
    case inputScroll(InputScrollPayload)
    case cameraStart(CameraStartPayload)
    case cameraStarted(CameraStartedPayload)
    case cameraList
    case cameraZoom(CameraZoomPayload)
    case cameraCameras(CameraListPayload)
    case cameraStop
    case authChallenge(AuthChallengePayload)
    case authResponse(AuthResponsePayload)
    case authOK
    case unknown(String)

    var typeString: String {
        switch self {
        case .hello: "hello"
        case .ping: "ping"
        case .pong: "pong"
        case .error: "error"
        case .pairRequest: "pair.request"
        case .pairAccept: "pair.accept"
        case .pairReject: "pair.reject"
        case .pairConfirm: "pair.confirm"
        case .pairAbort: "pair.abort"
        case .clipboardSet: "clipboard.set"
        case .ringStart: "ring.start"
        case .ringStop: "ring.stop"
        case .ringStopped: "ring.stopped"
        case .streamAttach: "stream.attach"
        case .fsList: "fs.list"
        case .fsSearch: "fs.search"
        case .fsEntries: "fs.entries"
        case .fsDownload: "fs.download"
        case .fsUpload: "fs.upload"
        case .fsTransferReady: "fs.transferReady"
        case .fsTransferResult: "fs.transferResult"
        case .fsThumb: "fs.thumb"
        case .fsThumbData: "fs.thumbData"
        case .mirrorStart: "mirror.start"
        case .mirrorNeedsConsent: "mirror.needsConsent"
        case .mirrorStarted: "mirror.started"
        case .mirrorStop: "mirror.stop"
        case .inputTap: "input.tap"
        case .inputSwipe: "input.swipe"
        case .inputKey: "input.key"
        case .inputText: "input.text"
        case .inputScroll: "input.scroll"
        case .cameraStart: "camera.start"
        case .cameraStarted: "camera.started"
        case .cameraList: "camera.list"
        case .cameraZoom: "camera.zoom"
        case .cameraCameras: "camera.cameras"
        case .cameraStop: "camera.stop"
        case .authChallenge: "auth.challenge"
        case .authResponse: "auth.response"
        case .authOK: "auth.ok"
        case .unknown(let type): type
        }
    }
}
