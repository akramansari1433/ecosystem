import CryptoKit
import Foundation
import Security

/// Pairing credentials for this Mac.
///
/// Deliberately keychain-free: the Mac no longer presents a TLS client
/// certificate (which required a `SecIdentity`, and therefore a keychain that
/// macOS kept prompting to unlock on every rebuild). Instead the Mac proves who
/// it is with an HMAC challenge-response over the pinned TLS channel, using a
/// secret derived when the user confirmed the pairing code. Everything lives in
/// 0600 files under Application Support.
struct PairingStore {
    static let directory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Ecosystem")

    private static var peerCertURL: URL {
        directory.appendingPathComponent("paired-peer.der")
    }

    private static var secretURL: URL {
        directory.appendingPathComponent("pair-secret.bin")
    }

    static var pinnedPeerCertificate: Data? {
        try? Data(contentsOf: peerCertURL)
    }

    static var sharedSecret: SymmetricKey? {
        guard let data = try? Data(contentsOf: secretURL) else { return nil }
        return SymmetricKey(data: data)
    }

    static var isPaired: Bool {
        pinnedPeerCertificate != nil && sharedSecret != nil
    }

    static func save(peerCertificate: Data, secret: SymmetricKey) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try peerCertificate.write(to: peerCertURL)
        let raw = secret.withUnsafeBytes { Data($0) }
        try raw.write(to: secretURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: secretURL.path)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: peerCertURL)
        try? FileManager.default.removeItem(at: secretURL)
    }

    /// Both devices derive the same secret from the phone's certificate and the
    /// nonce the Mac sent in `pair.request` — no extra round trip, and the
    /// verification code the user compared covers both inputs.
    static func deriveSecret(nonce: Data, peerCertificate: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: nonce),
            salt: peerCertificate,
            info: Data("ecosystem-auth-v1".utf8),
            outputByteCount: 32)
    }

    static func authResponse(nonce: Data, secret: SymmetricKey) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: nonce, using: secret)).hexString
    }

    /// Removes keychains created by earlier builds so macOS stops asking to
    /// unlock them. Safe to call on every launch.
    static func removeLegacyKeychains() {
        for name in ["ecosystem.keychain-db", "ecosystem-v2.keychain-db"] {
            let path = directory.appendingPathComponent(name).path
            guard FileManager.default.fileExists(atPath: path) else { continue }
            var keychain: SecKeychain?
            if SecKeychainOpen(path, &keychain) == errSecSuccess, let keychain {
                SecKeychainDelete(keychain)
            }
            try? FileManager.default.removeItem(atPath: path)
        }
        // Also drop the old client-certificate material; it is no longer used.
        for name in ["identity-key.raw", "identity-cert.der"] {
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent(name))
        }
    }
}
