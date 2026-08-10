import Foundation
import Testing

@testable import Ecosystem

struct BinaryFrameFixtures: Decodable {
    struct Case: Decodable {
        let name: String
        let frameType: Int
        let ptsMicros: Int64
        let payloadHex: String
        let framedHex: String
    }
    let cases: [Case]
}

struct BinaryFramesTests {
    let fixtures: BinaryFrameFixtures

    init() throws {
        let data = try Data(contentsOf: testVectorsURL("binary-frames.json"))
        fixtures = try JSONDecoder().decode(BinaryFrameFixtures.self, from: data)
    }

    @Test func encodesEveryFixtureByteExactly() {
        for c in fixtures.cases {
            let frame = BinaryFrames.encode(
                frameType: UInt8(c.frameType), ptsMicros: c.ptsMicros,
                payload: Data(hex: c.payloadHex)!)
            #expect(frame.hexString == c.framedHex, "case \(c.name)")
        }
    }

    @Test func readerDecodesEveryFixtureFromByteDribble() throws {
        let reader = BinaryFrameReader()
        var decoded: [BinaryFrame] = []
        for c in fixtures.cases {
            for byte in Data(hex: c.framedHex)! {
                decoded += try reader.append(Data([byte]))
            }
        }
        #expect(decoded.count == fixtures.cases.count)
        for (c, frame) in zip(fixtures.cases, decoded) {
            #expect(frame.frameType == UInt8(c.frameType), "case \(c.name)")
            #expect(frame.ptsMicros == c.ptsMicros, "case \(c.name)")
            #expect(frame.payload == Data(hex: c.payloadHex)!, "case \(c.name)")
        }
    }
}
