import Foundation
import Network
import os

private let log = Logger(subsystem: "com.akram.ecosystem", category: "browser")

/// Browses the LAN for the phone's `_ecosys._tcp` service.
@MainActor
final class DeviceBrowser {
    struct Device: Equatable {
        let name: String
        /// From the service's TXT record; identifies the phone across renames.
        let deviceId: String?
        let endpoint: NWEndpoint
        static func == (lhs: Device, rhs: Device) -> Bool {
            lhs.name == rhs.name && lhs.deviceId == rhs.deviceId
        }
    }

    var onDevicesChanged: (([Device]) -> Void)?
    /// Fired when the browser dies (network change, sleep) and must be restarted.
    var onNeedsRestart: (() -> Void)?
    private var browser: NWBrowser?

    func start() {
        browser?.stateUpdateHandler = nil   // its cancel must not look like a failure
        stop()
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_ecosys._tcp", domain: nil), using: .init())
        browser.stateUpdateHandler = { [weak self] state in
            log.info("browser state: \(String(describing: state), privacy: .public)")
            // Only a genuine failure warrants a restart. `.cancelled` is what our
            // own stop() produces — restarting on it loops forever.
            guard case .failed = state else { return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.onNeedsRestart?()
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            log.info("browse results: \(results.count) [\(results.map { String(describing: $0.endpoint) }.joined(separator: ", "), privacy: .public)]")
            let devices = results.compactMap { result -> Device? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                let display = name.replacingOccurrences(of: "Ecosystem-", with: "")
                var deviceId: String?
                if case .bonjour(let txt) = result.metadata {
                    deviceId = txt["deviceId"]
                }
                return Device(name: display, deviceId: deviceId, endpoint: result.endpoint)
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
