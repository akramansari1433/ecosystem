import Foundation
import Observation

@Observable
@MainActor
final class AppState {
    enum ConnectionStatus {
        case disconnected
        case searching
        case connected(deviceName: String)
    }

    var status: ConnectionStatus = .disconnected

    var statusText: String {
        switch status {
        case .disconnected: "Not connected"
        case .searching: "Looking for your phone…"
        case .connected(let name): "Connected to \(name)"
        }
    }

    var menuBarSymbol: String {
        switch status {
        case .connected: "iphone.gen3.radiowaves.left.and.right"
        default: "iphone.gen3.slash"
        }
    }
}
