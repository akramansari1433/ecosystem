import CryptoKit
import Foundation

/// Pure pairing state machine for the Mac, which always initiates. See
/// docs/protocol.md §5. Owns no I/O: callers feed `Input`s and execute the
/// returned `Effect`s. (The phone's mirror-image responder lives in the Android
/// app's PairingEngine.)
final class PairingEngine {
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
        case receivedAccept
        case receivedReject
        case receivedConfirm
        case receivedAbort(reason: String?)
        case userConfirmed
        case userRejected
    }

    enum Effect: Equatable {
        case send(Message)
        case displayCode(String)
        case persistPeerCert
        case complete
        case fail(reason: String)
    }

    private(set) var state: State = .idle
    private var peerConfirmed = false

    private let code: String
    private let ownFingerprint: String

    init(ownDer: Data, peerDer: Data) {
        self.code = PairingCode.derive(ownDer, peerDer)
        self.ownFingerprint = SHA256.hash(data: ownDer)
            .map { String(format: "%02x", $0) }.joined()
    }

    func handle(_ input: Input) -> [Effect] {
        if case .paired = state { return [] }
        if case .failed = state { return [] }

        switch (state, input) {
        case (.idle, .start):
            state = .requested
            return [.send(.pairRequest(.init(certFingerprint: ownFingerprint)))]

        case (.requested, .receivedAccept):
            state = .codeDisplayed
            return [.displayCode(code)]

        case (.requested, .receivedReject):
            return fail("rejected")

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

        // Cancellation, from any non-terminal state.
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
