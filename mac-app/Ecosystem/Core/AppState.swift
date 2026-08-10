import Foundation
import Observation

@Observable
@MainActor
final class AppState {
    enum Status: Equatable {
        case searching
        case foundUnpaired(String)
        case pairing
        case connected(String)
        case error(String)
    }

    var status: Status = .searching
    var paired = false
    var connected = false
    var phoneName: String?
    var discoveredPhone: String?
    var pairingCode: String?
    var ringing = false

    var statusText: String {
        switch status {
        case .searching:
            paired ? "Looking for your phone…" : "Not paired"
        case .foundUnpaired(let name):
            "Found \(name) — not paired yet"
        case .pairing:
            "Pairing…"
        case .connected(let name):
            "Connected to \(name)"
        case .error(let message):
            message
        }
    }

    var menuBarSymbol: String {
        connected ? "iphone.gen3.radiowaves.left.and.right" : "iphone.gen3.slash"
    }
}
