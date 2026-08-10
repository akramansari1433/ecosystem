import CryptoKit
import Foundation

/// Pure pairing state machine. See docs/protocol.md §5.
/// Owns no I/O: callers feed `Input`s and execute the returned `Effect`s.
final class PairingEngine {
    enum Role {
        case initiator  // Mac: sends pair.request
        case responder  // Phone: receives pair.request
    }

    enum State: Equatable {
        case idle
        case requested
        case codeDisplayed
        case confirmedLocal
        case paired
        case failed(String)
    }

    enum Input: Equatable {
        case start
        case receivedRequest(fingerprint: String)
        case receivedAccept
        case receivedReject
        case receivedConfirm
        case receivedAbort(reason: String?)
        case userAccepted
        case userConfirmed
        case userRejected
    }

    enum Effect: Equatable {
        case send(Message)
        case showAcceptPrompt(fingerprint: String)
        case displayCode(String)
        case persistPeerCert
        case complete
        case fail(reason: String)
    }

    private(set) var state: State = .idle
    private var peerConfirmed = false

    private let role: Role
    private let code: String
    private let ownFingerprint: String

    init(role: Role, ownDer: Data, peerDer: Data) {
        self.role = role
        self.code = PairingCode.derive(ownDer, peerDer)
        self.ownFingerprint = SHA256.hash(data: ownDer)
            .map { String(format: "%02x", $0) }.joined()
    }

    func handle(_ input: Input) -> [Effect] {
        if case .paired = state { return [] }
        if case .failed = state { return [] }

        switch (state, input) {
        // --- Initiator ---
        case (.idle, .start) where role == .initiator:
            state = .requested
            return [.send(.pairRequest(.init(certFingerprint: ownFingerprint)))]

        case (.requested, .receivedAccept) where role == .initiator:
            state = .codeDisplayed
            return [.displayCode(code)]

        case (.requested, .receivedReject) where role == .initiator:
            return fail("rejected")

        // --- Responder ---
        case (.idle, .receivedRequest(let fingerprint)) where role == .responder:
            state = .requested
            return [.showAcceptPrompt(fingerprint: fingerprint)]

        case (.requested, .userAccepted) where role == .responder:
            state = .codeDisplayed
            return [.send(.pairAccept), .displayCode(code)]

        case (.requested, .userRejected) where role == .responder:
            state = .failed("rejected")
            return [.send(.pairReject), .fail(reason: "rejected")]

        // --- Shared confirmation dance ---
        case (.codeDisplayed, .userConfirmed):
            if peerConfirmed {
                state = .paired
                return [.send(.pairConfirm), .persistPeerCert, .complete]
            }
            state = .confirmedLocal
            return [.send(.pairConfirm)]

        case (.codeDisplayed, .receivedConfirm):
            peerConfirmed = true
            return []

        case (.confirmedLocal, .receivedConfirm):
            state = .paired
            return [.persistPeerCert, .complete]

        // --- Cancellation, any non-terminal state ---
        case (_, .receivedAbort(let reason)):
            return fail(reason ?? "aborted")

        case (_, .userRejected):
            state = .failed("rejected")
            return [.send(.pairAbort(.init(reason: "rejected"))), .fail(reason: "rejected")]

        default:
            return []
        }
    }

    private func fail(_ reason: String) -> [Effect] {
        state = .failed(reason)
        return [.fail(reason: reason)]
    }
}
