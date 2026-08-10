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
        case .unknown(let type): type
        }
    }
}
