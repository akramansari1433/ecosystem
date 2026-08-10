import Foundation
import Network
import os

private let log = Logger(subsystem: "com.akram.ecosystem", category: "browser")

/// Browses the LAN for the phone's `_ecosys._tcp` service.
@MainActor
final class DeviceBrowser {
    struct Device: Equatable {
        let name: String
        let endpoint: NWEndpoint
        static func == (lhs: Device, rhs: Device) -> Bool { lhs.name == rhs.name }
    }

    var onDevicesChanged: (([Device]) -> Void)?
    /// Fired when the browser dies (network change, sleep) and must be restarted.
    var onNeedsRestart: (() -> Void)?
    private var browser: NWBrowser?

    func start() {
        stop()
        let browser = NWBrowser(
            for: .bonjour(type: "_ecosys._tcp", domain: nil), using: .init())
        browser.stateUpdateHandler = { [weak self] state in
            log.info("browser state: \(String(describing: state), privacy: .public)")
            switch state {
            case .failed, .cancelled:
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    self?.onNeedsRestart?()
                }
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            log.info("browse results: \(results.count) [\(results.map { String(describing: $0.endpoint) }.joined(separator: ", "), privacy: .public)]")
            let devices = results.compactMap { result -> Device? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                let display = name.replacingOccurrences(of: "Ecosystem-", with: "")
                return Device(name: display, endpoint: result.endpoint)
            }
            Task { @MainActor [weak self] in
                self?.onDevicesChanged?(devices)
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}
