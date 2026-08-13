import AppKit
import CryptoKit
import Foundation
import Network
import Observation
import os

private let log = Logger(subsystem: "com.akram.ecosystem", category: "manager")

/// Orchestrates discovery → connection → hello → auth/pairing → steady state,
/// and keeps the link alive across sleep, Wi-Fi changes and going out of range.
@MainActor
final class ConnectionManager {
    /// SwiftUI re-runs `App.init()` when a new window scene appears, so the app
    /// must not build its connection stack there: a second stack would open a
    /// second control connection, and the phone keeps only the newest — which
    /// looked like the connection dropping every time a window opened.
    static let shared = ConnectionManager(appState: AppState.shared)

    private let appState: AppState
    private let browser = DeviceBrowser()
    private var connection: ControlConnection?
    private var pairingEngine: PairingEngine?
    private var pairingNonce: Data?
    private var currentPeerDER: Data?
    private var devices: [DeviceBrowser.Device] = []
    private var deviceRotation = 0
    private var reconnectAttempt = 0
    private var connectTask: Task<Void, Never>?
    private var activeDevice: DeviceBrowser.Device?
    private var watchdog: Timer?

    private let clipboard = ClipboardSync()
    private let notifications = NotificationMirror()
    private var pendingReplies: [String: CheckedContinuation<InboundEnvelope, Error>] = [:]
    private(set) lazy var files = FileBrowserModel(manager: self)
    private(set) lazy var mirror = MirrorSession(manager: self)
    private(set) lazy var camera = CameraSession(manager: self)

    enum RequestError: LocalizedError {
        case notConnected
        case timeout
        case remote(String)

        var errorDescription: String? {
            switch self {
            case .notConnected: "Not connected to the phone"
            case .timeout: "The phone didn't respond"
            case .remote(let message): message
            }
        }
    }

    init(appState: AppState) {
        self.appState = appState
    }

    private var hasStarted = false

    /// True once this connection has said hello and been authenticated. Sending
    /// anything before that loses the message: the phone requires hello as the
    /// first frame and closes the connection otherwise, and it drops feature
    /// messages that arrive before authentication.
    private var isReadyForRequests = false

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        appState.paired = PairingStore.isPaired
        appState.status = .searching
        clipboard.onLocalCopy = { [weak self] payload in
            self?.send(.clipboardSet(payload))
        }
        clipboard.start()
        notifications.send = { [weak self] message in self?.send(message) }
        notifications.start()
        browser.onDevicesChanged = { [weak self] devices in
            self?.devicesChanged(devices)
        }
        browser.onNeedsRestart = { [weak self] in
            self?.restartBrowser(reason: "browser failed")
        }
        browser.start()
        observeWake()
        startWatchdog()
    }

    // MARK: staying connected

    /// NWBrowser dies silently when the network changes underneath it, and a
    /// connection can be half-open after sleep. Re-check every 15 s.
    private func startWatchdog() {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchdogTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func watchdogTick() {
        guard connection == nil else { return }
        if devices.isEmpty {
            restartBrowser(reason: "no devices seen")
        } else if connectTask == nil {
            log.info("watchdog: retrying connection")
            connect(to: devices[deviceRotation % devices.count])
        }
    }

    private func observeWake() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.restartBrowser(reason: "system wake")
                }
            }
        }
    }

    private var lastBrowserRestart = Date.distantPast

    private func restartBrowser(reason: String) {
        // Rate-limit: several triggers (wake, watchdog, failure) can fire at once.
        guard Date().timeIntervalSince(lastBrowserRestart) > 10 else { return }
        lastBrowserRestart = Date()
        log.info("restarting discovery (\(reason, privacy: .public))")
        devices = []
        reconnectAttempt = 0
        browser.start()
    }

    private func devicesChanged(_ found: [DeviceBrowser.Device]) {
        devices = found
        appState.discoveredPhone = found.first?.name
        guard let device = found.first else { return }
        if connection == nil && connectTask == nil {
            connect(to: device)
        }
    }

    private func connect(to device: DeviceBrowser.Device) {
        activeDevice = device
        let pinned = PairingStore.pinnedPeerCertificate
        log.info("connecting to \(device.name, privacy: .public) (paired: \(pinned != nil))")
        let conn = ControlConnection(endpoint: device.endpoint, pinnedPeerDER: pinned)
        connection = conn
        connectTask = Task { [weak self] in
            let events = await conn.start()
            for await event in events {
                await self?.handle(event: event, from: conn)
            }
            await MainActor.run { self?.connectTask = nil }
        }
    }

    /// Opens a stream connection to the connected phone (paired only).
    func openStream() throws -> StreamConnection {
        guard let activeDevice, let pinned = PairingStore.pinnedPeerCertificate else {
            throw RequestError.notConnected
        }
        return StreamConnection(endpoint: activeDevice.endpoint, pinnedPeerDER: pinned)
    }

    private func handle(event: ControlConnection.Event, from conn: ControlConnection) async {
        switch event {
        case .ready(let peerDER):
            currentPeerDER = peerDER
            reconnectAttempt = 0
            isReadyForRequests = false
            try? await conn.send(.hello(HelloPayload(
                capabilities: ["clipboard", "ring", "fs", "mirror", "input"],
                deviceId: Self.deviceId,
                name: Host.current().localizedName ?? "Mac",
                protocolVersion: 2)))

        case .message(let envelope):
            await handleMessage(envelope, conn: conn)

        case .closed:
            log.info("connection closed; scheduling reconnect")
            isReadyForRequests = false
            for (_, continuation) in pendingReplies {
                continuation.resume(throwing: RequestError.notConnected)
            }
            pendingReplies.removeAll()
            connection = nil
            pairingEngine = nil
            appState.connected = false
            appState.pairingCode = nil
            appState.status = .searching
            scheduleReconnect()
        }
    }

    /// Waits for the handshake to finish, so nothing jumps the queue ahead of
    /// hello and gets the connection closed.
    private func awaitReady(timeout: Double = 8) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !isReadyForRequests {
            guard Date() < deadline else { throw RequestError.notConnected }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Sends a request and awaits the correlated reply.
    func request(_ message: Message, timeout: Double = 15) async throws -> InboundEnvelope {
        try await awaitReady()
        guard let connection else { throw RequestError.notConnected }
        let id = UUID().uuidString.lowercased()
        let reply: InboundEnvelope = try await withCheckedThrowingContinuation { cont in
            pendingReplies[id] = cont
            Task {
                do {
                    try await connection.send(message, id: id)
                } catch {
                    self.pendingReplies.removeValue(forKey: id)?.resume(throwing: error)
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                self.pendingReplies.removeValue(forKey: id)?
                    .resume(throwing: RequestError.timeout)
            }
        }
        if case .error(let payload) = reply.message {
            throw RequestError.remote(payload.message ?? payload.code)
        }
        return reply
    }

    private func handleMessage(_ envelope: InboundEnvelope, conn: ControlConnection) async {
        if let replyTo = envelope.replyTo,
           let continuation = pendingReplies.removeValue(forKey: replyTo) {
            continuation.resume(returning: envelope)
            return
        }
        switch envelope.message {
        case .hello(let hello):
            guard hello.protocolVersion == 2 else {
                appState.status = .error("Update the phone app — protocol mismatch")
                await conn.close()
                return
            }
            appState.phoneName = hello.name
            appState.inputAvailable = hello.capabilities.contains("input")
            if PairingStore.isPaired {
                appState.status = .connected(hello.name)   // confirmed once auth.ok lands
            } else {
                // Unpaired: no auth step, so pairing messages may flow now.
                isReadyForRequests = true
                appState.status = .foundUnpaired(hello.name)
            }

        case .authChallenge(let challenge):
            // Pairing by QR: the phone already has the secret, derived from the
            // nonce this Mac put in the code. Derive the same one and answer.
            if PairingStore.sharedSecret == nil,
               let offer = PairingStore.scanOffer, offer.isFresh,
               let peerDER = currentPeerDER,
               let nonce = Data(hex: challenge.nonce) {
                let secret = PairingStore.deriveSecret(
                    nonce: offer.nonce, peerCertificate: peerDER)
                try? PairingStore.save(peerCertificate: peerDER, secret: secret)
                appState.paired = true
                try? await conn.send(.authResponse(.init(
                    mac: PairingStore.authResponse(nonce: nonce, secret: secret))),
                    replyTo: envelope.id)
                return
            }
            guard let secret = PairingStore.sharedSecret,
                  let nonce = Data(hex: challenge.nonce) else {
                // No secret on this Mac: it has never paired with this phone.
                PairingStore.clear()
                appState.paired = false
                isReadyForRequests = true
                appState.status = .foundUnpaired(appState.phoneName ?? "phone")
                return
            }
            try? await conn.send(.authResponse(.init(
                mac: PairingStore.authResponse(nonce: nonce, secret: secret))),
                replyTo: envelope.id)

        case .authOK:
            PairingStore.scanOffer = nil
            isReadyForRequests = true
            appState.connected = true
            if let name = appState.phoneName { appState.status = .connected(name) }
            log.info("authenticated")

        case .ping:
            try? await conn.send(.pong, replyTo: envelope.id)

        case .pairAccept:
            await runPairingEffects(pairingEngine?.handle(.receivedAccept) ?? [], conn: conn)
        case .pairReject:
            await runPairingEffects(pairingEngine?.handle(.receivedReject) ?? [], conn: conn)
        case .pairConfirm:
            await runPairingEffects(pairingEngine?.handle(.receivedConfirm) ?? [], conn: conn)
        case .pairAbort(let payload):
            await runPairingEffects(
                pairingEngine?.handle(.receivedAbort(reason: payload.reason)) ?? [], conn: conn)

        case .error(let payload) where payload.code == "pair_required":
            PairingStore.clear()
            appState.paired = false
            isReadyForRequests = true
            appState.status = .foundUnpaired(appState.phoneName ?? "phone")

        case .clipboardSet(let payload):
            clipboard.applyRemote(payload)

        case .ringStopped:
            appState.ringing = false

        case .notifyPosted(let payload):
            notifications.handlePosted(payload)

        case .notifyDismissed(let payload):
            notifications.handleDismissed(key: payload.key)

        case .fsTransferResult(let payload):
            files.handleTransferResult(payload)

        default:
            break
        }
    }

    // MARK: pairing

    /// Builds the payload for the QR code the phone scans. Generating a new offer
    /// invalidates the previous one.
    func makeScanOffer() -> String {
        var nonce = Data(count: 32)
        _ = nonce.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        PairingStore.scanOffer = .init(nonce: nonce, created: Date())
        let name = (Host.current().localizedName ?? "Mac")
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "Mac"
        return "ecosystem://pair?d=\(Self.deviceId)&n=\(nonce.hexString)&name=\(name)"
    }

    /// Forgets this phone on this Mac. The phone keeps its own record until it is
    /// removed there too, but this Mac will have to pair again to reconnect.
    func forgetPhone() {
        PairingStore.clear()
        PairingStore.scanOffer = nil
        appState.paired = false
        appState.connected = false
        appState.status = .searching
        isReadyForRequests = false
        Task { await connection?.close() }
    }

    func startPairing() {
        guard let currentPeerDER, let connection else { return }
        // A fresh nonce identifies this Mac and seeds the shared secret; the
        // 6-digit code covers both it and the phone's certificate.
        var nonce = Data(count: 32)
        _ = nonce.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        pairingNonce = nonce
        let engine = PairingEngine(ownDer: nonce, peerDer: currentPeerDER)
        pairingEngine = engine
        appState.status = .pairing
        Task { await runPairingEffects(engine.handle(.start), conn: connection) }
    }

    func confirmPairing() {
        guard let pairingEngine, let connection else { return }
        Task { await runPairingEffects(pairingEngine.handle(.userConfirmed), conn: connection) }
    }

    func cancelPairing() {
        guard let pairingEngine, let connection else { return }
        Task { await runPairingEffects(pairingEngine.handle(.userRejected), conn: connection) }
    }

    private func runPairingEffects(
        _ effects: [PairingEngine.Effect], conn: ControlConnection
    ) async {
        for effect in effects {
            switch effect {
            case .send(let message):
                // The nonce travels as the pair.request "fingerprint" field.
                if case .pairRequest = message, let nonce = pairingNonce {
                    try? await conn.send(.pairRequest(.init(certFingerprint: nonce.hexString)))
                } else {
                    try? await conn.send(message)
                }
            case .displayCode(let code):
                appState.pairingCode = code
            case .persistPeerCert:
                if let currentPeerDER, let nonce = pairingNonce {
                    try? PairingStore.save(
                        peerCertificate: currentPeerDER,
                        secret: PairingStore.deriveSecret(
                            nonce: nonce, peerCertificate: currentPeerDER))
                }
            case .complete:
                appState.paired = true
                appState.pairingCode = nil
                appState.status = .searching
                pairingNonce = nil
            case .fail(let reason):
                appState.pairingCode = nil
                appState.status = .error("Pairing failed: \(reason)")
                pairingNonce = nil
            }
        }
    }

    // MARK: outbound commands

    func toggleRing() {
        if appState.ringing {
            send(.ringStop)
            appState.ringing = false
        } else {
            send(.ringStart)
            appState.ringing = true
        }
    }

    func send(_ message: Message) {
        Task {
            try? await awaitReady(timeout: 4)
            guard let connection else { return }
            try? await connection.send(message)
        }
    }

    private func scheduleReconnect() {
        let delay = min(20.0, pow(1.7, Double(reconnectAttempt)))
        reconnectAttempt += 1
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.connection == nil, self.connectTask == nil,
                  !self.devices.isEmpty else { return }
            // Rotate through discovered records: a stale duplicate can linger in
            // mDNS caches after the phone app restarts.
            self.deviceRotation += 1
            self.connect(to: self.devices[self.deviceRotation % self.devices.count])
        }
    }

    private static var deviceId: String {
        let key = "ecosystem.deviceId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }
}
