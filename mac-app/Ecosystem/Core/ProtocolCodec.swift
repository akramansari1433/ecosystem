import Foundation

struct InboundEnvelope: Equatable {
    let id: String
    let replyTo: String?
    let message: Message
}

enum ProtocolCodec {
    enum CodecError: Error {
        case missingPayload(type: String)
    }

    // MARK: Encoding

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // Canonical form per docs/protocol.md §3: sorted keys, raw UTF-8, no \/ escapes.
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    private struct Wrapper<P: Encodable>: Encodable {
        let id: String
        let replyTo: String?
        let type: String
        let payload: P?

        enum CodingKeys: String, CodingKey { case id, replyTo, type, payload }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(replyTo, forKey: .replyTo)
            try c.encode(type, forKey: .type)
            try c.encodeIfPresent(payload, forKey: .payload)
        }
    }

    private struct NoPayload: Codable {}

    /// Encodes a complete wire frame: 4-byte BE length prefix + canonical JSON.
    static func encodeFrame(id: String, message: Message, replyTo: String? = nil) throws -> Data {
        let body: Data
        switch message {
        case .hello(let p): body = try encodeBody(id: id, replyTo: replyTo, type: message.typeString, payload: p)
        case .error(let p): body = try encodeBody(id: id, replyTo: replyTo, type: message.typeString, payload: p)
        case .pairRequest(let p): body = try encodeBody(id: id, replyTo: replyTo, type: message.typeString, payload: p)
        case .pairAbort(let p): body = try encodeBody(id: id, replyTo: replyTo, type: message.typeString, payload: p)
        case .clipboardSet(let p): body = try encodeBody(id: id, replyTo: replyTo, type: message.typeString, payload: p)
        case .streamAttach(let p): body = try encodeBody(id: id, replyTo: replyTo, type: message.typeString, payload: p)
        case .fsList(let p): body = try encodeBody(id: id, replyTo: replyTo, type: message.typeString, payload: p)
        case .fsSearch(let p): body = try encodeBody(id: id, replyTo: replyTo, type: message.typeString, payload: p)
        case .fsEntries(let p): body = try encodeBody(id: id, replyTo: replyTo, type: message.typeString, payload: p)
        case .fsDownload(let p): body = try encodeBody(id: id, replyTo: replyTo, type: message.typeString, payload: p)
        case .fsUpload(let p): body = try encodeBody(id: id, replyTo: replyTo, type: message.typeString, payload: p)
        case .fsTransferReady(let p): body = try encodeBody(id: id, replyTo: replyTo, type: message.typeString, payload: p)
        case .fsTransferResult(let p): body = try encodeBody(id: id, replyTo: replyTo, type: message.typeString, payload: p)
        case .fsThumb(let p): body = try encodeBody(id: id, replyTo: replyTo, type: message.typeString, payload: p)
        case .fsThumbData(let p): body = try encodeBody(id: id, replyTo: replyTo, type: message.typeString, payload: p)
        case .mirrorStart(let p): body = try encodeBody(id: id, replyTo: replyTo, type: message.typeString, payload: p)
        case .mirrorStarted(let p): body = try encodeBody(id: id, replyTo: replyTo, type: message.typeString, payload: p)
        case .inputTap(let p): body = try encodeBody(id: id, replyTo: replyTo, type: message.typeString, payload: p)
        case .inputSwipe(let p): body = try encodeBody(id: id, replyTo: replyTo, type: message.typeString, payload: p)
        case .inputKey(let p): body = try encodeBody(id: id, replyTo: replyTo, type: message.typeString, payload: p)
        case .inputText(let p): body = try encodeBody(id: id, replyTo: replyTo, type: message.typeString, payload: p)
        case .inputScroll(let p): body = try encodeBody(id: id, replyTo: replyTo, type: message.typeString, payload: p)
        case .cameraStart(let p): body = try encodeBody(id: id, replyTo: replyTo, type: message.typeString, payload: p)
        case .cameraStarted(let p): body = try encodeBody(id: id, replyTo: replyTo, type: message.typeString, payload: p)
        case .cameraCameras(let p): body = try encodeBody(id: id, replyTo: replyTo, type: message.typeString, payload: p)
        case .cameraZoom(let p): body = try encodeBody(id: id, replyTo: replyTo, type: message.typeString, payload: p)
        case .authChallenge(let p): body = try encodeBody(id: id, replyTo: replyTo, type: message.typeString, payload: p)
        case .authResponse(let p): body = try encodeBody(id: id, replyTo: replyTo, type: message.typeString, payload: p)
        case .notifyPosted(let p): body = try encodeBody(id: id, replyTo: replyTo, type: message.typeString, payload: p)
        case .notifyDismissed(let p): body = try encodeBody(id: id, replyTo: replyTo, type: message.typeString, payload: p)
        case .notifyAction(let p): body = try encodeBody(id: id, replyTo: replyTo, type: message.typeString, payload: p)
        case .notifyDismiss(let p): body = try encodeBody(id: id, replyTo: replyTo, type: message.typeString, payload: p)
        case .ping, .pong, .pairAccept, .pairReject, .pairConfirm,
             .ringStart, .ringStop, .ringStopped, .unknown,
             .mirrorNeedsConsent, .mirrorStop, .authOK, .cameraStop, .cameraList:
            body = try encodeBody(id: id, replyTo: replyTo, type: message.typeString,
                                  payload: nil as NoPayload?)
        }
        var frame = Data()
        var length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(body)
        return frame
    }

    private static func encodeBody<P: Encodable>(
        id: String, replyTo: String?, type: String, payload: P?
    ) throws -> Data {
        try encoder.encode(Wrapper(id: id, replyTo: replyTo, type: type, payload: payload))
    }

    // MARK: Decoding

    private struct Header: Decodable {
        let id: String
        let type: String
        let replyTo: String?
    }

    private struct Typed<P: Decodable>: Decodable {
        let payload: P?
    }

    /// Decodes one JSON frame payload (without the length prefix).
    static func decodeFrame(_ data: Data) throws -> InboundEnvelope {
        let header = try JSONDecoder().decode(Header.self, from: data)
        let message: Message
        switch header.type {
        case "hello": message = .hello(try payload(from: data, type: header.type))
        case "ping": message = .ping
        case "pong": message = .pong
        case "error": message = .error(try payload(from: data, type: header.type))
        case "pair.request": message = .pairRequest(try payload(from: data, type: header.type))
        case "pair.accept": message = .pairAccept
        case "pair.reject": message = .pairReject
        case "pair.confirm": message = .pairConfirm
        case "pair.abort": message = .pairAbort(try payload(from: data, type: header.type))
        case "clipboard.set": message = .clipboardSet(try payload(from: data, type: header.type))
        case "notify.posted": message = .notifyPosted(try payload(from: data, type: header.type))
        case "notify.dismissed": message = .notifyDismissed(try payload(from: data, type: header.type))
        case "notify.action": message = .notifyAction(try payload(from: data, type: header.type))
        case "notify.dismiss": message = .notifyDismiss(try payload(from: data, type: header.type))
        case "ring.start": message = .ringStart
        case "ring.stop": message = .ringStop
        case "ring.stopped": message = .ringStopped
        case "stream.attach": message = .streamAttach(try payload(from: data, type: header.type))
        case "fs.list": message = .fsList(try payload(from: data, type: header.type))
        case "fs.search": message = .fsSearch(try payload(from: data, type: header.type))
        case "fs.entries": message = .fsEntries(try payload(from: data, type: header.type))
        case "fs.download": message = .fsDownload(try payload(from: data, type: header.type))
        case "fs.upload": message = .fsUpload(try payload(from: data, type: header.type))
        case "fs.transferReady": message = .fsTransferReady(try payload(from: data, type: header.type))
        case "fs.transferResult": message = .fsTransferResult(try payload(from: data, type: header.type))
        case "fs.thumb": message = .fsThumb(try payload(from: data, type: header.type))
        case "fs.thumbData": message = .fsThumbData(try payload(from: data, type: header.type))
        case "mirror.start": message = .mirrorStart(try payload(from: data, type: header.type))
        case "mirror.needsConsent": message = .mirrorNeedsConsent
        case "mirror.started": message = .mirrorStarted(try payload(from: data, type: header.type))
        case "mirror.stop": message = .mirrorStop
        case "input.tap": message = .inputTap(try payload(from: data, type: header.type))
        case "input.swipe": message = .inputSwipe(try payload(from: data, type: header.type))
        case "input.key": message = .inputKey(try payload(from: data, type: header.type))
        case "input.text": message = .inputText(try payload(from: data, type: header.type))
        case "input.scroll": message = .inputScroll(try payload(from: data, type: header.type))
        case "camera.start": message = .cameraStart(try payload(from: data, type: header.type))
        case "camera.started": message = .cameraStarted(try payload(from: data, type: header.type))
        case "camera.list": message = .cameraList
        case "camera.zoom": message = .cameraZoom(try payload(from: data, type: header.type))
        case "camera.cameras": message = .cameraCameras(try payload(from: data, type: header.type))
        case "camera.stop": message = .cameraStop
        case "auth.challenge": message = .authChallenge(try payload(from: data, type: header.type))
        case "auth.response": message = .authResponse(try payload(from: data, type: header.type))
        case "auth.ok": message = .authOK
        default: message = .unknown(header.type)
        }
        return InboundEnvelope(id: header.id, replyTo: header.replyTo, message: message)
    }

    private static func payload<P: Decodable>(from data: Data, type: String) throws -> P {
        guard let p = try JSONDecoder().decode(Typed<P>.self, from: data).payload else {
            throw CodecError.missingPayload(type: type)
        }
        return p
    }
}

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
