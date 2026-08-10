import CryptoKit
import Foundation
import Testing

@testable import Ecosystem

private let derMac = Data([0x30, 0x82, 0x01, 0x0a, 0x02, 0x81])
private let derPhone = Data([0x30, 0x82, 0x02, 0x0b, 0x03, 0x82])
private let expectedCode = PairingCode.derive(derMac, derPhone)

private func macFingerprint() -> String {
    SHA256.hash(data: derMac).map { String(format: "%02x", $0) }.joined()
}

struct PairingEngineInitiatorTests {
    private func makeEngine() -> PairingEngine {
        PairingEngine(role: .initiator, ownDer: derMac, peerDer: derPhone)
    }

    @Test func happyPath() {
        let engine = makeEngine()

        let e1 = engine.handle(.start)
        #expect(e1 == [.send(.pairRequest(.init(certFingerprint: macFingerprint())))])
        #expect(engine.state == .requested)

        let e2 = engine.handle(.receivedAccept)
        #expect(e2 == [.displayCode(expectedCode)])
        #expect(engine.state == .codeDisplayed)

        let e3 = engine.handle(.userConfirmed)
        #expect(e3 == [.send(.pairConfirm)])
        #expect(engine.state == .confirmedLocal)

        let e4 = engine.handle(.receivedConfirm)
        #expect(e4 == [.persistPeerCert, .complete])
        #expect(engine.state == .paired)
    }

    @Test func peerConfirmArrivesBeforeLocalConfirm() {
        let engine = makeEngine()
        _ = engine.handle(.start)
        _ = engine.handle(.receivedAccept)

        let early = engine.handle(.receivedConfirm)
        #expect(early == [])
        #expect(engine.state == .codeDisplayed)

        let e = engine.handle(.userConfirmed)
        #expect(e == [.send(.pairConfirm), .persistPeerCert, .complete])
        #expect(engine.state == .paired)
    }

    @Test func rejectFails() {
        let engine = makeEngine()
        _ = engine.handle(.start)
        let e = engine.handle(.receivedReject)
        #expect(e == [.fail(reason: "rejected")])
        #expect(engine.state == .failed("rejected"))
    }

    @Test func abortMidFlowFails() {
        let engine = makeEngine()
        _ = engine.handle(.start)
        _ = engine.handle(.receivedAccept)
        let e = engine.handle(.receivedAbort(reason: "user cancelled"))
        #expect(e == [.fail(reason: "user cancelled")])
        #expect(engine.state == .failed("user cancelled"))
    }

    @Test func userRejectedSendsAbort() {
        let engine = makeEngine()
        _ = engine.handle(.start)
        _ = engine.handle(.receivedAccept)
        let e = engine.handle(.userRejected)
        #expect(e == [.send(.pairAbort(.init(reason: "rejected"))), .fail(reason: "rejected")])
        #expect(engine.state == .failed("rejected"))
    }

    @Test func terminalStatesIgnoreInputs() {
        let engine = makeEngine()
        _ = engine.handle(.start)
        _ = engine.handle(.receivedAccept)
        _ = engine.handle(.userConfirmed)
        _ = engine.handle(.receivedConfirm)
        #expect(engine.state == .paired)

        #expect(engine.handle(.receivedAbort(reason: "x")) == [])
        #expect(engine.handle(.userConfirmed) == [])
        #expect(engine.state == .paired)
    }
}

struct PairingEngineResponderTests {
    private func makeEngine() -> PairingEngine {
        PairingEngine(role: .responder, ownDer: derPhone, peerDer: derMac)
    }

    @Test func happyPath() {
        let engine = makeEngine()

        let e1 = engine.handle(.receivedRequest(fingerprint: macFingerprint()))
        #expect(e1 == [.showAcceptPrompt(fingerprint: macFingerprint())])
        #expect(engine.state == .requested)

        let e2 = engine.handle(.userAccepted)
        #expect(e2 == [.send(.pairAccept), .displayCode(expectedCode)])
        #expect(engine.state == .codeDisplayed)

        let e3 = engine.handle(.userConfirmed)
        #expect(e3 == [.send(.pairConfirm)])

        let e4 = engine.handle(.receivedConfirm)
        #expect(e4 == [.persistPeerCert, .complete])
        #expect(engine.state == .paired)
    }

    @Test func userRejectInRequestedSendsReject() {
        let engine = makeEngine()
        _ = engine.handle(.receivedRequest(fingerprint: macFingerprint()))
        let e = engine.handle(.userRejected)
        #expect(e == [.send(.pairReject), .fail(reason: "rejected")])
        #expect(engine.state == .failed("rejected"))
    }

    @Test func codesMatchAcrossRoles() {
        // Initiator and responder derive the same code regardless of who owns which cert.
        let initiator = PairingEngine(role: .initiator, ownDer: derMac, peerDer: derPhone)
        _ = initiator.handle(.start)
        let initiatorEffects = initiator.handle(.receivedAccept)

        let responder = makeEngine()
        _ = responder.handle(.receivedRequest(fingerprint: macFingerprint()))
        let responderEffects = responder.handle(.userAccepted)

        #expect(initiatorEffects == [.displayCode(expectedCode)])
        #expect(responderEffects.contains(.displayCode(expectedCode)))
    }
}
