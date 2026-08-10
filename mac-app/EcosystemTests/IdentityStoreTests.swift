import Foundation
import Testing
import X509

@testable import Ecosystem

struct IdentityStoreTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ecosys-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func createsSelfSignedP256CertAndReloadsIdentically() throws {
        let dir = try tempDir()
        let first = try IdentityStore.loadOrCreate(directory: dir)

        let cert = try Certificate(derEncoded: Array(first.certificateDER))
        #expect(cert.subject.description.contains("Ecosystem-Mac"))
        #expect(cert.subject == cert.issuer)
        #expect(cert.notValidAfter > Date().addingTimeInterval(9 * 365 * 86400))

        let second = try IdentityStore.loadOrCreate(directory: dir)
        #expect(first.certificateDER == second.certificateDER)
    }

    @Test func distinctDirectoriesYieldDistinctCerts() throws {
        let a = try IdentityStore.loadOrCreate(directory: tempDir())
        let b = try IdentityStore.loadOrCreate(directory: tempDir())
        #expect(a.certificateDER != b.certificateDER)
    }

    @Test func signaturesVerifyWithStoredKey() throws {
        let identity = try IdentityStore.loadOrCreate(directory: tempDir())
        let message = Data("hello".utf8)
        let signature = try identity.privateKey.signature(for: message)
        #expect(identity.privateKey.publicKey.isValidSignature(signature, for: message))
    }
}
