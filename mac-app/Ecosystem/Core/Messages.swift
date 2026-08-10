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
        case .unknown(let type): type
        }
    }
}
