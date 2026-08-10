import Foundation

/// Incremental parser for the control-connection framing:
/// [uint32 big-endian length][payload]. See docs/protocol.md §2.1.
final class FrameReader {
    static let maxFrameBytes = 1_048_576

    enum FrameError: Error, Equatable {
        case oversizedFrame(declared: Int)
    }

    private var buffer = Data()

    /// Feed received bytes; returns every complete frame payload now available.
    func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length <= Self.maxFrameBytes else {
                throw FrameError.oversizedFrame(declared: length)
            }
            guard buffer.count >= 4 + length else { break }
            frames.append(Data(buffer.dropFirst(4).prefix(length)))
            buffer = Data(buffer.dropFirst(4 + length))
        }
        return frames
    }
}
