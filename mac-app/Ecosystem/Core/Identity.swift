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

enum KeychainIdentityError: LocalizedError {
    case badCertificate
    case keychainCreateFailed(OSStatus)
    case importFailed(OSStatus)
    case identityCreationFailed(OSStatus)

    var errorDescription: String? {
        func text(_ s: OSStatus) -> String {
            SecCopyErrorMessageString(s, nil).map(String.init(describing:)) ?? "\(s)"
        }
        switch self {
        case .badCertificate: return "certificate is not valid DER"
        case .keychainCreateFailed(let s): return "keychain create/open failed: \(text(s))"
        case .importFailed(let s): return "key import failed: \(text(s))"
        case .identityCreationFailed(let s): return "identity creation failed: \(text(s))"
        }
    }
}

/// Materializes a `SecIdentity` (required by Network.framework for the TLS client
/// certificate) from the file-backed identity.
///
/// Uses a dedicated legacy keychain file owned by the app instead of the login /
/// data-protection keychain: an ad-hoc-signed app gets errSecMissingEntitlement
/// (-34018) from `SecItemAdd(kSecClassKey…)` on modern macOS, and a private
/// keychain also avoids "allow access" prompts after every rebuild. The key goes
/// in via `SecItemImport`, which only understands SEC1 (not PKCS#8) EC keys.
enum KeychainIdentity {
    private static let password = "ecosystem-local"

    static func secIdentity(
        for store: IdentityStore,
        directory: URL = IdentityStore.defaultDirectory
    ) throws -> SecIdentity {
        guard let certificate = SecCertificateCreateWithData(
            nil, store.certificateDER as CFData) else {
            throw KeychainIdentityError.badCertificate
        }
        // The keychain is recreated from scratch on EVERY launch. Keychain item
        // ACLs are bound to the creating binary's code signature, and ad-hoc dev
        // builds get a new signature on every rebuild — reusing a keychain across
        // builds is what causes macOS password popups. Durable state (key, cert,
        // pairing pin) lives in plain files; the keychain is a disposable bridge
        // to the SecIdentity that Network.framework requires.
        for stale in ["ecosystem.keychain-db", "ecosystem-v2.keychain-db"] {
            deleteKeychainIfPresent(at: directory.appendingPathComponent(stale).path)
        }
        let keychain = try openOrCreateKeychain(
            at: directory.appendingPathComponent("ecosystem-v2.keychain-db").path)
        var identity: SecIdentity?

        let access = try permissiveAccess()
        var params = SecItemImportExportKeyParameters()
        params.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
        params.accessRef = Unmanaged.passUnretained(access)
        var keyFormat = SecExternalFormat.formatOpenSSL
        var keyType = SecExternalItemType.itemTypePrivateKey
        let sec1 = sec1DER(
            privateRaw: store.privateKey.rawRepresentation,
            publicX963: store.privateKey.publicKey.x963Representation)
        let keyStatus = withExtendedLifetime(access) {
            SecItemImport(
                sec1 as CFData, nil, &keyFormat, &keyType, [], &params, keychain, nil)
        }
        guard keyStatus == errSecSuccess || keyStatus == errSecDuplicateItem else {
            throw KeychainIdentityError.importFailed(keyStatus)
        }

        var certFormat = SecExternalFormat.formatUnknown
        var certType = SecExternalItemType.itemTypeCertificate
        let certStatus = SecItemImport(
            store.certificateDER as CFData, nil, &certFormat, &certType, [], nil,
            keychain, nil)
        guard certStatus == errSecSuccess || certStatus == errSecDuplicateItem else {
            throw KeychainIdentityError.importFailed(certStatus)
        }

        let status = SecIdentityCreateWithCertificate(keychain, certificate, &identity)
        guard status == errSecSuccess, let identity else {
            throw KeychainIdentityError.identityCreationFailed(status)
        }
        return identity
    }

    /// An access object whose ACLs trust ANY application with no passphrase prompt.
    /// Rebuilt ad-hoc binaries have a new code signature, so a default ACL would
    /// prompt for the keychain password after every build. The private key already
    /// lives unencrypted in a 0600 file beside the keychain, so an open item ACL
    /// does not weaken anything.
    private static func permissiveAccess() throws -> SecAccess {
        var access: SecAccess?
        let status = SecAccessCreate("Ecosystem identity key" as CFString, nil, &access)
        guard status == errSecSuccess, let access else {
            throw KeychainIdentityError.importFailed(status)
        }
        var aclList: CFArray?
        if SecAccessCopyACLList(access, &aclList) == errSecSuccess,
           let acls = aclList as? [SecACL] {
            for acl in acls {
                var appList: CFArray?
                var description: CFString?
                var prompt = SecKeychainPromptSelector()
                guard SecACLCopyContents(acl, &appList, &description, &prompt)
                    == errSecSuccess else { continue }
                // NULL application list = trust every application; empty prompt
                // selector = never require the keychain passphrase.
                SecACLSetContents(acl, nil, description ?? "" as CFString,
                                  SecKeychainPromptSelector())
            }
        }
        return access
    }

    // Only touched from ConnectionManager's MainActor flow.
    nonisolated(unsafe) private static var openedKeychain: SecKeychain?

    /// Unlocks the app keychain (no-op if not yet opened). Called before TLS
    /// dials: macOS can lock keychains on sleep, and a locked keychain turns the
    /// TLS signing step into a password prompt.
    static func ensureUnlocked() {
        guard let keychain = openedKeychain else { return }
        _ = password.withCString {
            SecKeychainUnlock(keychain, UInt32(strlen($0)), $0, true)
        }
    }

    /// Disables auto-locking and unlocks. The key in here also sits in a plain
    /// 0600 file, so keeping the keychain unlocked adds prompts-free operation
    /// without weakening anything.
    private static func configure(_ keychain: SecKeychain) {
        openedKeychain = keychain
        var settings = SecKeychainSettings(
            version: UInt32(SEC_KEYCHAIN_SETTINGS_VERS1),
            lockOnSleep: false, useLockInterval: false, lockInterval: UInt32.max)
        SecKeychainSetSettings(keychain, &settings)
        _ = password.withCString {
            SecKeychainUnlock(keychain, UInt32(strlen($0)), $0, true)
        }
    }

    /// Removing the file alone leaves a phantom registration in securityd
    /// (recreating at the same path then fails with errSecDuplicateKeychain);
    /// SecKeychainDelete unregisters AND removes the file.
    private static func deleteKeychainIfPresent(at path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        var keychain: SecKeychain?
        if SecKeychainOpen(path, &keychain) == errSecSuccess, let keychain {
            SecKeychainDelete(keychain)
        }
        try? FileManager.default.removeItem(atPath: path)
    }

    private static func openOrCreateKeychain(at path: String) throws -> SecKeychain {
        var keychain: SecKeychain?
        if FileManager.default.fileExists(atPath: path) {
            let status = SecKeychainOpen(path, &keychain)
            guard status == errSecSuccess, let keychain else {
                throw KeychainIdentityError.keychainCreateFailed(status)
            }
            configure(keychain)
            return keychain
        }
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let status = password.withCString {
            SecKeychainCreate(path, UInt32(strlen($0)), $0, false, nil, &keychain)
        }
        guard status == errSecSuccess, let keychain else {
            throw KeychainIdentityError.keychainCreateFailed(status)
        }
        return keychain
    }

    /// SEC1 ECPrivateKey DER for P-256 (RFC 5915) — fixed-size template.
    private static func sec1DER(privateRaw: Data, publicX963: Data) -> Data {
        precondition(privateRaw.count == 32 && publicX963.count == 65)
        var der = Data([0x30, 0x77])                        // SEQUENCE (119)
        der += [0x02, 0x01, 0x01]                           // INTEGER 1
        der += [0x04, 0x20]                                 // OCTET STRING (32)
        der += privateRaw
        der += [0xa0, 0x0a, 0x06, 0x08,                     // [0] OID prime256v1
                0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07]
        der += [0xa1, 0x44, 0x03, 0x42, 0x00]               // [1] BIT STRING (65)
        der += publicX963
        return der
    }
}
