import Foundation
import Testing

@testable import Ecosystem

private func framed(_ payload: Data) -> Data {
    var out = Data()
    var len = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
    out.append(payload)
    return out
}

struct FrameReaderTests {
    @Test func singleFrame() throws {
        let reader = FrameReader()
        let payload = Data(#"{"type":"ping"}"#.utf8)
        let frames = try reader.append(framed(payload))
        #expect(frames == [payload])
    }

    @Test func frameSplitByteByByte() throws {
        let reader = FrameReader()
        let payload = Data(#"{"type":"pong"}"#.utf8)
        let wire = framed(payload)
        var collected: [Data] = []
        for byte in wire {
            collected += try reader.append(Data([byte]))
        }
        #expect(collected == [payload])
    }

    @Test func twoFramesCoalesced() throws {
        let reader = FrameReader()
        let a = Data(#"{"n":1}"#.utf8)
        let b = Data(#"{"n":2}"#.utf8)
        let frames = try reader.append(framed(a) + framed(b))
        #expect(frames == [a, b])
    }

    @Test func oversizedFrameThrows() {
        let reader = FrameReader()
        var header = Data()
        var len = UInt32(FrameReader.maxFrameBytes + 1).bigEndian
        withUnsafeBytes(of: &len) { header.append(contentsOf: $0) }
        #expect(throws: FrameReader.FrameError.self) {
            _ = try reader.append(header)
        }
    }
}
