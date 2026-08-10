import Foundation
import Testing

@testable import Ecosystem

/// Locates protocol/test-vectors by walking up from this source file.
func testVectorsURL(_ name: String) -> URL {
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while dir.path != "/" {
        let candidate = dir.appendingPathComponent("protocol/test-vectors/\(name)")
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        dir.deleteLastPathComponent()
    }
    fatalError("test vectors not found for \(name)")
}

struct EnvelopeFixtures: Decodable {
    struct Case: Decodable {
        let name: String
        let json: String
        let framedHex: String
    }
    let maxFrameBytes: Int
    let cases: [Case]
}

/// The typed message each fixture case must decode to.
private let expectedMessages: [String: (id: String, replyTo: String?, message: Message)] = [
    "hello": ("00000000-0000-4000-8000-000000000001", nil,
              .hello(.init(capabilities: ["clipboard", "ring"],
                           deviceId: "11111111-2222-4333-8444-555555555555",
                           name: "Akram's Mac", protocolVersion: 1))),
    "ping": ("00000000-0000-4000-8000-000000000002", nil, .ping),
    "pong-reply": ("00000000-0000-4000-8000-000000000003",
                   "00000000-0000-4000-8000-000000000002", .pong),
    "pair.request": ("00000000-0000-4000-8000-000000000004", nil,
                     .pairRequest(.init(certFingerprint: String(repeating: "a", count: 64)))),
    "pair.confirm": ("00000000-0000-4000-8000-000000000005", nil, .pairConfirm),
    "clipboard.set": ("00000000-0000-4000-8000-000000000006", nil,
                      .clipboardSet(.init(text: "héllo wörld 👋", tsMillis: 1_754_870_400_000))),
    "ring.start": ("00000000-0000-4000-8000-000000000007", nil, .ringStart),
    "error": ("00000000-0000-4000-8000-000000000008", nil,
              .error(.init(code: "version_mismatch", message: nil))),
    "stream.attach": ("00000000-0000-4000-8000-000000000009", nil,
                      .streamAttach(.init(kind: "file", token: "tok-123"))),
    "fs.list": ("00000000-0000-4000-8000-00000000000a", nil,
                .fsList(.init(path: "/storage/emulated/0/DCIM"))),
    "fs.entries": ("00000000-0000-4000-8000-00000000000b",
                   "00000000-0000-4000-8000-00000000000a",
                   .fsEntries(.init(entries: [
                       FsEntry(isDir: true, mtimeMillis: 1_754_870_400_000,
                               name: "Camera", size: 0),
                       FsEntry(isDir: false, mtimeMillis: 1_754_870_401_000,
                               name: "pic.jpg", size: 123_456),
                   ]))),
    "fs.download": ("00000000-0000-4000-8000-00000000000c", nil,
                    .fsDownload(.init(path: "/storage/emulated/0/DCIM/pic.jpg"))),
    "fs.upload": ("00000000-0000-4000-8000-00000000000d", nil,
                  .fsUpload(.init(destPath: "/storage/emulated/0/Download/doc.pdf",
                                  size: 99_000))),
    "fs.transferReady": ("00000000-0000-4000-8000-00000000000e",
                         "00000000-0000-4000-8000-00000000000c",
                         .fsTransferReady(.init(size: 123_456, token: "tok-dl-1"))),
    "fs.transferResult": ("00000000-0000-4000-8000-00000000000f", nil,
                          .fsTransferResult(.init(
                              message: nil, ok: true,
                              sha256: String(repeating: "ab", count: 32),
                              token: "tok-dl-1"))),
]

struct ProtocolCodecTests {
    let fixtures: EnvelopeFixtures

    init() throws {
        let data = try Data(contentsOf: testVectorsURL("envelope.json"))
        fixtures = try JSONDecoder().decode(EnvelopeFixtures.self, from: data)
    }

    @Test func encodesEveryFixtureByteExactly() throws {
        for c in fixtures.cases {
            let expected = expectedMessages[c.name]!
            let framed = try ProtocolCodec.encodeFrame(
                id: expected.id, message: expected.message, replyTo: expected.replyTo)
            #expect(framed.hexString == c.framedHex, "case \(c.name)")
        }
    }

    @Test func decodesEveryFixture() throws {
        for c in fixtures.cases {
            let expected = expectedMessages[c.name]!
            let inbound = try ProtocolCodec.decodeFrame(Data(c.json.utf8))
            #expect(inbound.id == expected.id, "case \(c.name)")
            #expect(inbound.replyTo == expected.replyTo, "case \(c.name)")
            #expect(inbound.message == expected.message, "case \(c.name)")
        }
    }

    @Test func unknownTypeDecodesToUnknown() throws {
        let json = #"{"id":"x","type":"future.thing"}"#
        let inbound = try ProtocolCodec.decodeFrame(Data(json.utf8))
        #expect(inbound.message == .unknown("future.thing"))
    }

    @Test func missingPayloadForTypedMessageThrows() {
        let json = #"{"id":"x","type":"clipboard.set"}"#
        #expect(throws: (any Error).self) {
            _ = try ProtocolCodec.decodeFrame(Data(json.utf8))
        }
    }
}
