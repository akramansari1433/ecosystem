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
