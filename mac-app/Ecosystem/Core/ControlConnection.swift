import Foundation
import Network
import os
import Security

private let log = Logger(subsystem: "com.akram.ecosystem", category: "connection")

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
    private var receiveTask: Task<Void, Never>?
    private var lastReceived = Date()
    private var closed = false
    private var isReady = false

    init(endpoint: NWEndpoint, pinnedPeerDER: Data?) {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
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

        // Nagle delays small frames (every request here is small) by up to
        // ~200 ms while it waits to coalesce; disable it for snappy round trips.
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        connection = NWConnection(to: endpoint, using: NWParameters(tls: tls, tcp: tcp))
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
        // Connect timeout: a dial to a stale Bonjour record can sit in .preparing
        // forever; give up so the manager can rotate to another discovered record.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            await self?.abandonIfNotReady()
        }
        return stream
    }

    private func abandonIfNotReady() {
        if !isReady && !closed {
            log.info("connect timeout; abandoning")
            finish()
        }
    }

    func send(
        _ message: Message, replyTo: String? = nil,
        id: String = UUID().uuidString.lowercased()
    ) throws {
        let frame = try ProtocolCodec.encodeFrame(id: id, message: message, replyTo: replyTo)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    func close() {
        finish()
    }

    private func handleState(_ state: NWConnection.State) {
        log.info("connection state: \(String(describing: state), privacy: .public)")
        switch state {
        case .ready:
            isReady = true
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

    /// Reads sequentially: each chunk is awaited before the next is requested, so
    /// bytes reach the frame reader in wire order. (Spawning a Task per receive
    /// callback could reassemble a multi-chunk reply out of order and corrupt it.)
    private func receiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while await !self.isClosed {
                do {
                    let (data, isComplete) = try await self.receiveChunk()
                    if let data, !data.isEmpty {
                        try await self.ingest(data)
                    }
                    if isComplete { break }
                } catch {
                    break
                }
            }
            await self.finish()
        }
    }

    private var isClosed: Bool { closed }

    private func receiveChunk() async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                data, _, isComplete, error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: (data, isComplete))
                }
            }
        }
    }

    private func ingest(_ data: Data) throws {
        lastReceived = Date()
        for frame in try reader.append(data) {
            continuation?.yield(.message(try ProtocolCodec.decodeFrame(frame)))
        }
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
        receiveTask?.cancel()
        connection.cancel()
        continuation?.yield(.closed)
        continuation?.finish()
    }
}
