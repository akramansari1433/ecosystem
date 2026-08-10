import CryptoKit
import Foundation
import Network
import os
import os.lock

private let log = Logger(subsystem: "com.akram.ecosystem", category: "stream")

/// One short-lived TLS stream connection (docs/protocol.md §2.2, §9): dials the
/// phone, sends `stream.attach`, then moves file bytes in binary frames.
actor StreamConnection {
    enum StreamError: Error {
        case connectFailed
        case interrupted
        case sizeMismatch(expected: Int64, got: Int64)
    }

    private let connection: NWConnection

    init(endpoint: NWEndpoint, identity: SendableIdentity, pinnedPeerDER: Data) {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        if let secIdentity = sec_identity_create(identity.identity) {
            sec_protocol_options_set_local_identity(sec, secIdentity)
        }
        sec_protocol_options_set_verify_block(sec, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard
                let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                let leaf = chain.first
            else {
                complete(false)
                return
            }
            complete((SecCertificateCopyData(leaf) as Data) == pinnedPeerDER)
        }, DispatchQueue(label: "ecosystem.stream-verify"))
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        connection = NWConnection(to: endpoint, using: NWParameters(tls: tls, tcp: tcp))
    }

    private func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            connection.stateUpdateHandler = { state in
                let first = resumed.withLock { done -> Bool in
                    if done { return false }
                    switch state {
                    case .ready, .failed, .cancelled, .waiting:
                        done = true
                        return true
                    default:
                        return false
                    }
                }
                guard first else { return }
                if case .ready = state {
                    cont.resume()
                } else {
                    cont.resume(throwing: StreamError.connectFailed)
                }
            }
            connection.start(queue: DispatchQueue(label: "ecosystem.stream"))
        }
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    private func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) {
                data, _, isComplete, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if isComplete {
                    cont.resume(returning: nil)
                } else {
                    cont.resume(returning: Data())
                }
            }
        }
    }

    private func attach(token: String) async throws {
        try await start()
        try await send(try ProtocolCodec.encodeFrame(
            id: UUID().uuidString.lowercased(),
            message: .streamAttach(.init(kind: "file", token: token))))
    }

    /// Downloads the stream to [destination]; returns the SHA-256 hex of the bytes.
    func download(
        token: String, to destination: URL, expectedSize: Int64,
        onProgress: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> String {
        try await attach(token: token)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close(); connection.cancel() }

        let reader = BinaryFrameReader()
        var hasher = SHA256()
        var received: Int64 = 0
        while true {
            guard let data = try await receive() else { throw StreamError.interrupted }
            for frame in try reader.append(data) {
                if frame.frameType == BinaryFrames.typeEnd {
                    guard received == expectedSize else {
                        throw StreamError.sizeMismatch(expected: expectedSize, got: received)
                    }
                    return Data(hasher.finalize()).hexString
                }
                try handle.write(contentsOf: frame.payload)
                hasher.update(data: frame.payload)
                received += Int64(frame.payload.count)
                onProgress?(received)
            }
        }
    }

    /// Streams the local file [source] to the phone.
    func upload(
        token: String, from source: URL,
        onProgress: (@Sendable (Int64) -> Void)? = nil
    ) async throws {
        try await attach(token: token)
        defer { connection.cancel() }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var offset: Int64 = 0
        while let chunk = try handle.read(upToCount: BinaryFrames.fileChunkBytes),
              !chunk.isEmpty {
            try await send(BinaryFrames.encode(
                frameType: BinaryFrames.typeFileChunk, ptsMicros: offset, payload: chunk))
            offset += Int64(chunk.count)
            onProgress?(offset)
        }
        try await send(BinaryFrames.encode(
            frameType: BinaryFrames.typeEnd, ptsMicros: 0, payload: Data()))
        // Give the final frame time to flush before the deferred cancel.
        try? await Task.sleep(for: .milliseconds(300))
        log.info("upload stream complete (\(offset) bytes)")
    }
}
