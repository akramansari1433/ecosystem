import CryptoKit
import Foundation

/// Verification code shown on both devices during pairing. See docs/protocol.md §5:
/// uint24(first 3 bytes of SHA-256(concat(sorted([derA, derB])))) mod 1e6, zero-padded.
enum PairingCode {
    static func derive(_ derA: Data, _ derB: Data) -> String {
        let sorted = lexicographicallyOrdered(derA, derB)
        let digest = SHA256.hash(data: sorted.0 + sorted.1)
        let bytes = Array(digest.prefix(3))
        let value = (Int(bytes[0]) << 16 | Int(bytes[1]) << 8 | Int(bytes[2])) % 1_000_000
        return String(format: "%06d", value)
    }

    private static func lexicographicallyOrdered(_ a: Data, _ b: Data) -> (Data, Data) {
        a.lexicographicallyPrecedes(b) ? (a, b) : (b, a)
    }
}
