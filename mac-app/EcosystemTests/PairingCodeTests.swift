import Foundation
import Testing

@testable import Ecosystem

struct PairingCodeFixtures: Decodable {
    struct Case: Decodable {
        let name: String
        let derAHex: String
        let derBHex: String
        let expectedCode: String
    }
    let cases: [Case]
}

extension Data {
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

struct PairingCodeTests {
    @Test func derivesEveryFixtureCode() throws {
        let data = try Data(contentsOf: testVectorsURL("pairing-codes.json"))
        let fixtures = try JSONDecoder().decode(PairingCodeFixtures.self, from: data)
        #expect(!fixtures.cases.isEmpty)
        for c in fixtures.cases {
            let derA = Data(hex: c.derAHex)!
            let derB = Data(hex: c.derBHex)!
            #expect(PairingCode.derive(derA, derB) == c.expectedCode, "case \(c.name)")
            #expect(PairingCode.derive(derB, derA) == c.expectedCode, "case \(c.name) swapped")
        }
    }

    @Test func alwaysSixDigits() {
        let code = PairingCode.derive(Data([0x01]), Data([0x02]))
        #expect(code.count == 6)
        #expect(code.allSatisfy { $0.isNumber })
    }
}
