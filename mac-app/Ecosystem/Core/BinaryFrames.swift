import Foundation

/// Stream-connection binary framing (docs/protocol.md §2.2):
/// [uint32 BE length][uint8 frameType][int64 BE ptsMicros][payload]
/// where length counts frameType + ptsMicros + payload.
struct BinaryFrame: Equatable {
    let frameType: UInt8
    let ptsMicros: Int64
    let payload: Data
}

enum BinaryFrames {
    static let typeCodecConfig: UInt8 = 0
    static let typeKeyframe: UInt8 = 1
    static let typeAudio: UInt8 = 5
    static let typeDelta: UInt8 = 2
    static let typeFileChunk: UInt8 = 3
    static let typeEnd: UInt8 = 4

    static let maxFrameBytes = 8 * 1024 * 1024
    static let fileChunkBytes = 256 * 1024

    static func encode(frameType: UInt8, ptsMicros: Int64, payload: Data) -> Data {
        var frame = Data(capacity: 13 + payload.count)
        var length = UInt32(1 + 8 + payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(frameType)
        var pts = UInt64(bitPattern: ptsMicros).bigEndian
        withUnsafeBytes(of: &pts) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }
}

final class BinaryFrameReader {
    enum FrameError: Error {
        case invalidLength(declared: Int)
    }

    private var buffer = Data()

    func append(_ data: Data) throws -> [BinaryFrame] {
        buffer.append(data)
        var frames: [BinaryFrame] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length >= 9, length <= BinaryFrames.maxFrameBytes else {
                throw FrameError.invalidLength(declared: length)
            }
            guard buffer.count >= 4 + length else { break }
            let body = buffer.dropFirst(4).prefix(length)
            let frameType = body[body.startIndex]
            let ptsBytes = body.dropFirst(1).prefix(8)
            let pts = ptsBytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            frames.append(BinaryFrame(
                frameType: frameType,
                ptsMicros: Int64(bitPattern: pts),
                payload: Data(body.dropFirst(9))))
            buffer = Data(buffer.dropFirst(4 + length))
        }
        return frames
    }
}
