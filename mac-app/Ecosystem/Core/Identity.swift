import CryptoKit
import Foundation
import Security
import SwiftASN1
import X509

/// This Mac's long-lived TLS identity: a P-256 key and self-signed certificate,
/// persisted as files in Application Support. See docs/protocol.md §1, §5.
struct IdentityStore {
    let privateKey: P256.Signing.PrivateKey
    let certificateDER: Data

    static let defaultDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Ecosystem")

    static func loadOrCreate(directory: URL = defaultDirectory) throws -> IdentityStore {
        let keyURL = directory.appendingPathComponent("identity-key.raw")
        let certURL = directory.appendingPathComponent("identity-cert.der")

        if let keyData = try? Data(contentsOf: keyURL),
           let certData = try? Data(contentsOf: certURL) {
            return IdentityStore(
                privateKey: try P256.Signing.PrivateKey(rawRepresentation: keyData),
                certificateDER: certData)
        }

        let key = P256.Signing.PrivateKey()
        let certKey = Certificate.PrivateKey(key)
        let name = try DistinguishedName { CommonName("Ecosystem-Mac") }
        let certificate = try Certificate(
            version: .v3,
            serialNumber: .init(),
            publicKey: certKey.publicKey,
            notValidBefore: Date().addingTimeInterval(-86_400),
            notValidAfter: Date().addingTimeInterval(10 * 365 * 86_400),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions(),
            issuerPrivateKey: certKey)
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        let der = Data(serializer.serializedBytes)

        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try key.rawRepresentation.write(to: keyURL, options: [.completeFileProtection])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        try der.write(to: certURL)
        return IdentityStore(privateKey: key, certificateDER: der)
    }
}

enum KeychainIdentityError: Error {
    case keyImportFailed
    case addFailed(OSStatus)
    case identityCreationFailed(OSStatus)
}

/// Materializes a `SecIdentity` (required by Network.framework for the TLS client
/// certificate) from the file-backed identity, importing into the login keychain
/// once and reusing it afterwards.
enum KeychainIdentity {
    private static let label = "com.akram.ecosystem.identity"

    static func secIdentity(for store: IdentityStore) throws -> SecIdentity {
        guard let certificate = SecCertificateCreateWithData(
            nil, store.certificateDER as CFData) else {
            throw KeychainIdentityError.keyImportFailed
        }

        // Import the private key (idempotent: duplicate item errors are fine).
        let keyAttrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ]
        guard let secKey = SecKeyCreateWithData(
            store.privateKey.x963Representation as CFData, keyAttrs as CFDictionary, nil)
        else { throw KeychainIdentityError.keyImportFailed }

        let addKey: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecValueRef: secKey,
            kSecAttrLabel: label,
        ]
        let keyStatus = SecItemAdd(addKey as CFDictionary, nil)
        guard keyStatus == errSecSuccess || keyStatus == errSecDuplicateItem else {
            throw KeychainIdentityError.addFailed(keyStatus)
        }

        let addCert: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecValueRef: certificate,
            kSecAttrLabel: label,
        ]
        let certStatus = SecItemAdd(addCert as CFDictionary, nil)
        guard certStatus == errSecSuccess || certStatus == errSecDuplicateItem else {
            throw KeychainIdentityError.addFailed(certStatus)
        }

        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(nil, certificate, &identity)
        guard status == errSecSuccess, let identity else {
            throw KeychainIdentityError.identityCreationFailed(status)
        }
        return identity
    }
}
