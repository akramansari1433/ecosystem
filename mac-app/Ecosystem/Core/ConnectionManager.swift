import Foundation
import Network
import Observation

/// Orchestrates discovery → connection → hello → pairing → steady state,
/// and reconnects with backoff. Drives all `AppState` updates.
@MainActor
final class ConnectionManager {
    private let appState: AppState
    private let browser = DeviceBrowser()
    private var identity: IdentityStore?
    private var secIdentity: SendableIdentity?
    private var connection: ControlConnection?
    private var pairingEngine: PairingEngine?
    private var currentPeerDER: Data?
    private var currentDevice: DeviceBrowser.Device?
    private var reconnectAttempt = 0
    private var connectTask: Task<Void, Never>?

    private let clipboard = ClipboardSync()

    private var pairedPeerURL: URL {
        IdentityStore.defaultDirectory.appendingPathComponent("paired-peer.der")
    }

    init(appState: AppState) {
        self.appState = appState
    }

    func start() {
        do {
            let identity = try IdentityStore.loadOrCreate()
            self.identity = identity
            self.secIdentity = SendableIdentity(
                identity: try KeychainIdentity.secIdentity(for: identity))
        } catch {
            appState.status = .error("Identity setup failed: \(error.localizedDescription)")
            return
        }
        appState.paired = FileManager.default.fileExists(atPath: pairedPeerURL.path)
        appState.status = .searching
        clipboard.onLocalCopy = { [weak self] payload in
            self?.send(.clipboardSet(payload))
        }
        clipboard.start()
        browser.onDevicesChanged = { [weak self] devices in
            self?.devicesChanged(devices)
        }
        browser.start()
    }

    private func devicesChanged(_ devices: [DeviceBrowser.Device]) {
        appState.discoveredPhone = devices.first?.name
        guard let device = devices.first else { return }
        currentDevice = device
        if connection == nil {
            connect(to: device)
        }
    }

    private func connect(to device: DeviceBrowser.Device) {
        guard let secIdentity else { return }
        let pinned = try? Data(contentsOf: pairedPeerURL)
        let conn = ControlConnection(
            endpoint: device.endpoint, identity: secIdentity, pinnedPeerDER: pinned)
        connection = conn
        connectTask = Task { [weak self] in
            let events = await conn.start()
            for await event in events {
                await self?.handle(event: event, from: conn, device: device)
            }
        }
    }

    private func handle(
        event: ControlConnection.Event, from conn: ControlConnection,
        device: DeviceBrowser.Device
    ) async {
        switch event {
        case .ready(let peerDER):
            currentPeerDER = peerDER
            reconnectAttempt = 0
            try? await conn.send(.hello(HelloPayload(
                capabilities: ["clipboard", "ring"],
                deviceId: Self.deviceId,
                name: Host.current().localizedName ?? "Mac",
                protocolVersion: 1)))

        case .message(let envelope):
            await handleMessage(envelope, conn: conn)

        case .closed:
            connection = nil
            pairingEngine = nil
            appState.connected = false
            appState.pairingCode = nil
            appState.status = appState.paired ? .searching : .searching
            scheduleReconnect()
        }
    }

    private func handleMessage(_ envelope: InboundEnvelope, conn: ControlConnection) async {
        switch envelope.message {
        case .hello(let hello):
            guard hello.protocolVersion == 1 else {
                try? await conn.send(.error(.init(code: "version_mismatch", message: nil)))
                await conn.close()
                return
            }
            appState.connected = true
            appState.phoneName = hello.name
            appState.status = appState.paired
                ? .connected(hello.name)
                : .foundUnpaired(hello.name)

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

        case .clipboardSet(let payload):
            clipboard.applyRemote(payload)

        case .ringStopped:
            appState.ringing = false

        default:
            break
        }
    }

    // MARK: pairing (user actions from UI)

    func startPairing() {
        guard let identity, let currentPeerDER, let connection else { return }
        let engine = PairingEngine(
            role: .initiator, ownDer: identity.certificateDER, peerDer: currentPeerDER)
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
                try? await conn.send(message)
            case .displayCode(let code):
                appState.pairingCode = code
            case .persistPeerCert:
                if let currentPeerDER {
                    try? FileManager.default.createDirectory(
                        at: IdentityStore.defaultDirectory, withIntermediateDirectories: true)
                    try? currentPeerDER.write(to: pairedPeerURL)
                }
            case .complete:
                appState.paired = true
                appState.pairingCode = nil
                appState.status = .searching
                // Phone drops the connection; we reconnect in pinned mode.
            case .fail(let reason):
                appState.pairingCode = nil
                appState.status = .error("Pairing failed: \(reason)")
            case .showAcceptPrompt:
                break // responder-only
            }
        }
    }

    func unpair() {
        try? FileManager.default.removeItem(at: pairedPeerURL)
        appState.paired = false
        Task { await connection?.close() }
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
        guard let connection else { return }
        Task { try? await connection.send(message) }
    }

    private func scheduleReconnect() {
        let delay = min(30.0, pow(2.0, Double(reconnectAttempt)))
        reconnectAttempt += 1
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.connection == nil else { return }
            if let device = self.currentDevice {
                self.connect(to: device)
            }
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
