import Foundation
import Network
import Security

/// `SecIdentity` is a thread-safe CF type, but not marked Sendable; this wrapper
/// lets it cross actor boundaries.
struct SendableIdentity: @unchecked Sendable {
    let identity: SecIdentity
}

/// Thread-safe capture of the peer's leaf certificate observed during the TLS
/// handshake (the verify block runs on an arbitrary dispatch queue).
final class PeerCertificateCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var der: Data?

    func store(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        der = data
    }

    var value: Data? {
        lock.lock(); defer { lock.unlock() }
        return der
    }
}

/// One TLS control connection to the phone. See docs/protocol.md §1–§4.
actor ControlConnection {
    enum Event {
        case ready(peerDER: Data)
        case message(InboundEnvelope)
        case closed
    }

    enum ConnectionError: Error {
        case cancelled
    }

    private let connection: NWConnection
    private let capture = PeerCertificateCapture()
    private let reader = FrameReader()
    private var continuation: AsyncStream<Event>.Continuation?
    private var pingTask: Task<Void, Never>?
    private var lastReceived = Date()
    private var closed = false

    init(endpoint: NWEndpoint, identity: SendableIdentity, pinnedPeerDER: Data?) {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        if let secIdentity = sec_identity_create(identity.identity) {
            sec_protocol_options_set_local_identity(sec, secIdentity)
        }
        let capture = self.capture
        sec_protocol_options_set_verify_block(sec, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard
                let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                let leaf = chain.first
            else {
                complete(false)
                return
            }
            let der = SecCertificateCopyData(leaf) as Data
            capture.store(der)
            // TOFU: accept anything before pairing; exact DER match after.
            if let pinned = pinnedPeerDER {
                complete(der == pinned)
            } else {
                complete(true)
            }
        }, DispatchQueue(label: "ecosystem.tls-verify"))

        connection = NWConnection(to: endpoint, using: NWParameters(tls: tls))
    }

    /// Starts the connection; events (ready / messages / closed) arrive on the stream.
    func start() -> AsyncStream<Event> {
        let stream = AsyncStream<Event> { continuation in
            self.continuation = continuation
        }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.handleState(state) }
        }
        connection.start(queue: DispatchQueue(label: "ecosystem.connection"))
        return stream
    }

    func send(_ message: Message, replyTo: String? = nil) throws {
        let frame = try ProtocolCodec.encodeFrame(
            id: UUID().uuidString.lowercased(), message: message, replyTo: replyTo)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    func close() {
        finish()
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            if let der = capture.value {
                continuation?.yield(.ready(peerDER: der))
            }
            lastReceived = Date()
            receiveLoop()
            startPing()
        case .waiting:
            // Connection refused or unreachable (e.g. stale Bonjour record after the
            // phone re-registered). NWConnection would idle here indefinitely; fail
            // fast so the manager re-dials with fresh resolution and backoff.
            finish()
        case .failed, .cancelled:
            finish()
        default:
            break
        }
    }

    private func receiveLoop() {
        connection.receive(
            minimumIncompleteLength: 1, maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task { await self.handleReceive(data: data, isComplete: isComplete, error: error) }
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: NWError?) {
        if let data, !data.isEmpty {
            lastReceived = Date()
            do {
                for frame in try reader.append(data) {
                    let envelope = try ProtocolCodec.decodeFrame(frame)
                    continuation?.yield(.message(envelope))
                }
            } catch {
                finish()
                return
            }
        }
        if isComplete || error != nil {
            finish()
            return
        }
        receiveLoop()
    }

    private func startPing() {
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                await self?.pingTick()
            }
        }
    }

    private func pingTick() {
        guard !closed else { return }
        if Date().timeIntervalSince(lastReceived) > 30 {
            finish()
            return
        }
        try? send(.ping)
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        pingTask?.cancel()
        connection.cancel()
        continuation?.yield(.closed)
        continuation?.finish()
    }
}
