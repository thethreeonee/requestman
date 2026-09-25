import CryptoKit
import Foundation
import Security
import Testing
import X509
@testable import RequestmanCertificates

struct LocalCertificateServiceTests {
    @Test func generatesSelfSignedRootWithConstrainedCAProfileAndRandomSerial() throws {
        let key = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let first = try CertificateMaterial.root(privateKey: key, now: testDate)
        let second = try CertificateMaterial.root(privateKey: key, now: testDate)
        #expect(first.serialNumber != second.serialNumber)
        #expect(first.publicKey.isValidSignature(first.signature, for: first))
        #expect(first.subject == first.issuer)
        #expect(try first.extensions.basicConstraints == .isCertificateAuthority(maxPathLength: 0))
        #expect(try first.extensions.keyUsage == KeyUsage(keyCertSign: true, cRLSign: true))
        #expect(first.extensions[oid: .X509ExtensionID.basicConstraints]?.critical == true)
        #expect(first.extensions[oid: .X509ExtensionID.keyUsage]?.critical == true)
        #expect(try first.extensions.subjectKeyIdentifier == SubjectKeyIdentifier(hash: key.publicKey))
        #expect(first.notValidAfter.timeIntervalSince(testDate) == 5 * 365 * 24 * 60 * 60)
        let data = try CertificateMaterial.data(first)
        #expect(try CertificateMaterial.decodeRoot(data, privateKey: key) == first)
    }

    @Test func secKeySigningRequiresNoPrivateKeyExport() throws {
        let parameters: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrIsPermanent as String: false
        ]
        let key = try #require(SecKeyCreateRandomKey(parameters as CFDictionary, nil))
        let privateKey = try Certificate.PrivateKey(key)
        let root = try CertificateMaterial.root(privateKey: privateKey, now: testDate)
        #expect(root.publicKey.isValidSignature(root.signature, for: root))
        let probeData = try CertificateMaterial.probe(root: root, privateKey: privateKey, now: testDate)
        let probe = try Certificate(derEncoded: Array(probeData))
        #expect(root.publicKey.isValidSignature(probe.signature, for: probe))
        #expect(try probe.extensions.subjectAlternativeNames == SubjectAlternativeNames([.dnsName("requestman.invalid")]))
    }

    @Test func customSignerUsesCertificatePublicKeyAndCannotExportPrivateKey() throws {
        let raw = try #require(SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256, kSecAttrIsPermanent: false
        ] as CFDictionary, nil))
        let publicKey = try Certificate.PrivateKey(raw).publicKey
        let key = Certificate.PrivateKey(KeychainSigningKey(key: raw, publicKey: publicKey))
        let root = try CertificateMaterial.root(privateKey: key, now: testDate)
        #expect(root.publicKey.isValidSignature(root.signature, for: root))
        let leaf = try CertificateMaterial.serverIdentity(host: "example.com", root: root,
            privateKey: key, now: testDate, expiresAt: testDate + 3600)
        let certificate = try Certificate(derEncoded: Array(leaf.certificateDER))
        #expect(root.publicKey.isValidSignature(certificate.signature, for: certificate))
        #expect(throws: LocalCertificateError.privateKeyExportForbidden) { try key.serializeAsPEM() }

        // A caller-supplied public key must not mask a mismatched actual signing key.
        let wrongPublicKey = Certificate.PrivateKey(P256.Signing.PrivateKey()).publicKey
        let wrong = Certificate.PrivateKey(KeychainSigningKey(key: raw, publicKey: wrongPublicKey))
        let wrongRoot = try CertificateMaterial.root(privateKey: .init(P256.Signing.PrivateKey()), now: testDate)
        #expect(throws: LocalCertificateError.privateKeyMismatch) {
            try CertificateMaterial.decodeRoot(CertificateMaterial.data(wrongRoot), privateKey: wrong)
        }
        let other = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let otherRoot = try CertificateMaterial.root(privateKey: other, now: testDate)
        let disguised = Certificate.PrivateKey(KeychainSigningKey(key: raw, publicKey: other.publicKey))
        #expect(throws: LocalCertificateError.privateKeyMismatch) {
            try CertificateMaterial.decodeRoot(CertificateMaterial.data(otherRoot), privateKey: disguised)
        }
    }

    @Test func runtimeCannotPromptAndSetupPersistsAuthorizationAcrossServiceRestart() async throws {
        let fixture = MemoryCertificates()
        let service = fixture.service()
        _ = try await service.generate()
        _ = try await service.install()
        _ = try await service.trust()
        fixture.requireAuthorization()
        await #expect(throws: LocalCertificateError.authorizationRequired) { try await service.status() }
        await #expect(throws: LocalCertificateError.authorizationRequired) {
            try await service.serverIdentity(for: "example.com")
        }
        #expect(fixture.snapshot().interactiveKeyReads == 0)
        let original = fixture.snapshot().document
        _ = try await service.generate() // Explicit setup repairs authorization, reuses CA.
        let restarted = fixture.service()
        #expect(try await restarted.status().trusted)
        #expect(try await restarted.serverIdentity(for: "example.com") != nil)
        #expect(fixture.snapshot().document == original)
        #expect(fixture.snapshot().keyCreates == 1)
        #expect(fixture.snapshot().authorizationRepairs == 1)
    }

    @Test func migrationReusesExistingCAAndDoesNotChangeTrust() async throws {
        let fixture = MemoryCertificates()
        let service = fixture.service()
        _ = try await service.generate()
        _ = try await service.install()
        _ = try await service.trust()
        let original = fixture.snapshot()
        fixture.requireAuthorization()
        let migrated = try await service.migrateAuthorization(allowingUI: true)
        #expect(migrated.trusted)
        #expect(try await fixture.service().status().trusted)
        _ = try await service.migrateAuthorization(allowingUI: true)
        let after = fixture.snapshot()
        #expect(after.authorizationRepairs == 1)
        #expect(after.keyCreates == original.keyCreates)
        #expect(after.installs == original.installs)
        #expect(after.trusts == original.trusts)
        #expect(after.document == original.document)
        #expect(after.removedCertificates.isEmpty)
        #expect(after.interactiveKeyReads == 0)
    }

    @Test func silentMigrationCannotEscalateOrReplaceTheCA() async throws {
        let fixture = MemoryCertificates()
        let service = fixture.service()
        _ = try await service.generate()
        fixture.requireAuthorization()
        await #expect(throws: LocalCertificateError.authorizationRequired) {
            try await service.migrateAuthorization(allowingUI: false)
        }
        #expect(fixture.snapshot().authorizationRepairs == 0)
        #expect(fixture.snapshot().keyCreates == 1)
        #expect(fixture.snapshot().installs == 0)
        #expect(fixture.snapshot().trusts == 0)
    }

    @Test func migrationDoesNotSetUpMissingCertificatesOrRepairDamagedMaterial() async throws {
        let empty = MemoryCertificates()
        #expect(try await empty.service().migrateAuthorization(allowingUI: true) == .missing)
        #expect(empty.snapshot().keyCreates == 0)
        let damaged = MemoryCertificates(document: Data([0, 1, 2]))
        await #expect(throws: LocalCertificateError.invalidCertificate) {
            try await damaged.service().migrateAuthorization(allowingUI: true)
        }
        #expect(damaged.snapshot().authorizationRepairs == 0)
        #expect(damaged.snapshot().document == Data([0, 1, 2]))
    }

    @Test func cancelledMigrationLeavesRuntimeNoninteractive() async throws {
        let fixture = MemoryCertificates()
        let service = fixture.service()
        _ = try await service.generate()
        fixture.requireAuthorization(cancelRepair: true)
        await #expect(throws: CancellationError.self) {
            try await service.migrateAuthorization(allowingUI: true)
        }
        await #expect(throws: LocalCertificateError.authorizationRequired) { try await service.status() }
        #expect(fixture.snapshot().interactiveKeyReads == 0)
        #expect(fixture.snapshot().authorizationRepairs == 0)
    }

    @Test func cancelledSetupDoesNotEnableBackgroundAuthorization() async throws {
        let fixture = MemoryCertificates()
        let service = fixture.service()
        _ = try await service.generate()
        _ = try await service.install()
        _ = try await service.trust()
        fixture.requireAuthorization(cancelRepair: true)
        await #expect(throws: CancellationError.self) { try await service.generate() }
        await #expect(throws: LocalCertificateError.authorizationRequired) { try await service.status() }
        await #expect(throws: LocalCertificateError.authorizationRequired) {
            try await service.serverIdentity(for: "example.com")
        }
        #expect(fixture.snapshot().interactiveKeyReads == 0)
    }

    @Test func interactionScopeRestoresPolicyAfterNestedFailure() throws {
        try CertificateKeychainInteraction.perform(allowingUI: true) {
            #expect(Self.interactionAllowed())
            #expect(throws: LocalCertificateError.authorizationRequired) {
                try CertificateKeychainInteraction.perform(allowingUI: false) {
                    #expect(!Self.interactionAllowed())
                    throw LocalCertificateError.authorizationRequired
                }
            }
            #expect(Self.interactionAllowed())
        }
    }

    private static func interactionAllowed() -> Bool {
        var allowed = DarwinBoolean(false)
        #expect(SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess)
        return allowed.boolValue
    }

    @Test func lifecycleIsIdempotentAndUsesActualTrustResult() async throws {
        let fixture = MemoryCertificates()
        let service = fixture.service()
        #expect(try await service.status() == .missing)
        #expect(fixture.snapshot().keyCreates == 0)
        let generated = try await service.generate()
        #expect(generated.generated && !generated.installed && !generated.trusted)
        #expect(try await service.generate() == generated)
        let installed = try await service.install()
        #expect(installed.installed && !installed.trusted)
        #expect(try await service.install() == installed)
        let trusted = try await service.trust()
        #expect(trusted.trusted)
        #expect(try await service.trust() == trusted)
        #expect(fixture.snapshot().keyCreates == 1)
        #expect(fixture.snapshot().installs == 1)
        #expect(fixture.snapshot().trusts == 1)
        #expect(generated.fingerprint == trusted.fingerprint)
    }

    @Test func authorizationCancellationPreservesKeyAndInstalledCertificate() async throws {
        let fixture = MemoryCertificates(cancelTrustOnce: true)
        let service = fixture.service()
        let original = try await service.generate()
        _ = try await service.install()
        await #expect(throws: CancellationError.self) { try await service.trust() }
        let afterCancellation = try await service.status()
        #expect(afterCancellation.installed && !afterCancellation.trusted)
        #expect(afterCancellation.fingerprint == original.fingerprint)
        let resumed = try await service.trust()
        #expect(resumed.trusted)
        #expect(fixture.snapshot().keyCreates == 1)
        #expect(fixture.snapshot().installs == 1)
        #expect(fixture.snapshot().trusts == 2)
    }

    @Test func successfulTrustWriteCannotMaskFailedVerification() async throws {
        let fixture = MemoryCertificates(trustTakesEffect: false)
        let service = fixture.service()
        _ = try await service.generate()
        _ = try await service.install()
        await #expect(throws: LocalCertificateError.trustNotEffective) { try await service.trust() }
        #expect(try await !service.status().trusted)
    }

    @Test func corruptedCertificateIsNeverOverwritten() async {
        let fixture = MemoryCertificates(key: .init(P256.Signing.PrivateKey()), document: Data([0, 1, 2]))
        await #expect(throws: LocalCertificateError.invalidCertificate) { try await fixture.service().generate() }
        #expect(fixture.snapshot().document == Data([0, 1, 2]))
        #expect(fixture.snapshot().keyCreates == 0)
    }

    @Test func missingAndMismatchedKeysNeverReplaceExistingCA() async throws {
        let key = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let data = try CertificateMaterial.data(CertificateMaterial.root(privateKey: key, now: testDate))
        let missing = MemoryCertificates(document: data)
        await #expect(throws: LocalCertificateError.missingPrivateKey) { try await missing.service().generate() }
        #expect(missing.snapshot().keyCreates == 0)
        let mismatched = MemoryCertificates(key: .init(P256.Signing.PrivateKey()), document: data)
        await #expect(throws: LocalCertificateError.privateKeyMismatch) { try await mismatched.service().generate() }
        #expect(mismatched.snapshot().document == data)
        #expect(mismatched.snapshot().keyCreates == 0)
    }

    @Test(arguments: [false, true])
    func explicitRegenerationRecoversDeletedPrivateKey(certificateStillInstalled: Bool) async throws {
        let oldKey = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let oldData = try CertificateMaterial.data(CertificateMaterial.root(privateKey: oldKey, now: testDate))
        let fixture = MemoryCertificates(document: oldData, installed: certificateStillInstalled ? oldData : nil)
        let service = fixture.service()
        await #expect(throws: LocalCertificateError.missingPrivateKey) { try await service.status() }
        await #expect(throws: LocalCertificateError.missingPrivateKey) { try await service.generate() }
        #expect(fixture.snapshot().keyCreates == 0)
        #expect(fixture.snapshot().document == oldData)
        let regenerated = try await service.regenerate()
        #expect(regenerated.generated && !regenerated.installed && !regenerated.trusted)
        #expect(regenerated.fingerprint != CertificateMaterial.fingerprint(oldData))
        #expect(fixture.snapshot().removedCertificates == [oldData])
        _ = try await service.install()
        #expect(try await service.trust().trusted)
        #expect(try await fixture.service().serverIdentity(for: "example.com") != nil)
        #expect(fixture.snapshot().keyCreates == 1)
    }

    @Test func missingInstalledCertificateReusesSurvivingPrivateKey() async throws {
        let key = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let data = try CertificateMaterial.data(CertificateMaterial.root(privateKey: key, now: testDate))
        let fixture = MemoryCertificates(key: key, document: data)
        let service = fixture.service()
        #expect(try await !service.status().installed)
        // Even a stale regenerate button must not replace a surviving identity.
        #expect(try await service.regenerate().fingerprint == CertificateMaterial.fingerprint(data))
        _ = try await service.install()
        #expect(try await service.trust().trusted)
        #expect(fixture.snapshot().keyCreates == 0)
        #expect(fixture.snapshot().removedCertificates.isEmpty)
    }

    @Test func regenerationRetriesAfterSaveFailureWithoutCreatingAnotherKey() async throws {
        let key = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let data = try CertificateMaterial.data(CertificateMaterial.root(privateKey: key, now: testDate))
        let fixture = MemoryCertificates(document: data, installed: data, failWriteOnce: true)
        let service = fixture.service()
        await #expect(throws: CocoaError.self) { try await service.regenerate() }
        #expect(fixture.snapshot().keyCreates == 1)
        #expect(fixture.snapshot().document == nil)
        #expect(fixture.snapshot().installed == nil)
        #expect(try await service.regenerate().generated)
        #expect(fixture.snapshot().keyCreates == 1)
    }

    @Test func cancelledRemovalKeepsRecoveryAvailableAndPreservesPublicFile() async throws {
        let key = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let data = try CertificateMaterial.data(CertificateMaterial.root(privateKey: key, now: testDate))
        let fixture = MemoryCertificates(document: data, installed: data, cancelRemovalOnce: true)
        let service = fixture.service()
        await #expect(throws: CancellationError.self) { try await service.regenerate() }
        #expect(fixture.snapshot().document == data)
        #expect(fixture.snapshot().installed == data)
        #expect(fixture.snapshot().keyCreates == 0)
        #expect(try await service.regenerate().generated)
    }

    @Test func regenerationNeverTreatsDeniedAccessAsDeletion() async throws {
        let key = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let data = try CertificateMaterial.data(CertificateMaterial.root(privateKey: key, now: testDate))
        let fixture = MemoryCertificates(key: key, document: data, installed: data)
        fixture.requireAuthorization()
        await #expect(throws: LocalCertificateError.authorizationRequired) { try await fixture.service().regenerate() }
        #expect(fixture.snapshot().removedCertificates.isEmpty)
        #expect(fixture.snapshot().document == data)
        #expect(fixture.snapshot().keyCreates == 0)
    }

    @Test func regenerationDoesNotRemoveAnUnrelatedInstalledCertificate() async throws {
        let key = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let data = try CertificateMaterial.data(CertificateMaterial.root(privateKey: key, now: testDate))
        let other = try CertificateMaterial.data(CertificateMaterial.root(privateKey: key, now: testDate))
        let fixture = MemoryCertificates(document: data, installed: other)
        await #expect(throws: LocalCertificateError.multipleCertificates) { try await fixture.service().regenerate() }
        #expect(fixture.snapshot().removedCertificates.isEmpty)
        #expect(fixture.snapshot().document == data)
        #expect(fixture.snapshot().installed == other)
        #expect(fixture.snapshot().keyCreates == 0)
    }

    @Test func missingPublicFileRecoversExistingInstalledCA() async throws {
        let key = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let data = try CertificateMaterial.data(CertificateMaterial.root(privateKey: key, now: testDate))
        let fixture = MemoryCertificates(key: key, installed: data)
        let status = try await fixture.service().generate()
        #expect(status.installed)
        #expect(fixture.snapshot().document == data)
        #expect(fixture.snapshot().keyCreates == 0)
    }

    @Test func expiredCAIsReportedAndNeverRenewedAutomatically() async throws {
        let key = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let data = try CertificateMaterial.data(CertificateMaterial.root(privateKey: key, now: testDate - 6 * 365 * 24 * 60 * 60))
        let fixture = MemoryCertificates(key: key, document: data, installed: data)
        let service = fixture.service()
        #expect(try await service.status().isExpired)
        await #expect(throws: LocalCertificateError.expiredCertificate) { try await service.generate() }
        await #expect(throws: LocalCertificateError.expiredCertificate) { try await service.install() }
        await #expect(throws: LocalCertificateError.expiredCertificate) { try await service.trust() }
        #expect(fixture.snapshot().document == data)
        #expect(fixture.snapshot().keyCreates == 0)
        #expect(fixture.snapshot().trusts == 0)
    }

    @Test func interruptedPublicFileSaveReusesKeyOnRetry() async throws {
        let fixture = MemoryCertificates(failWriteOnce: true)
        let service = fixture.service()
        await #expect(throws: CocoaError.self) { try await service.generate() }
        #expect(fixture.snapshot().keyCreates == 1)
        #expect(fixture.snapshot().document == nil)
        #expect(try await service.generate().generated)
        #expect(fixture.snapshot().keyCreates == 1)
    }

    @Test func leafIssuanceRequiresTrustAndNeverChangesSetup() async throws {
        let fixture = MemoryCertificates()
        let service = fixture.service()
        #expect(try await service.serverIdentity(for: "example.com") == nil)
        #expect(fixture.snapshot().keyCreates == 0)
        _ = try await service.generate()
        _ = try await service.install()
        #expect(try await service.serverIdentity(for: "example.com") == nil)
        #expect(fixture.snapshot().trusts == 0)
        _ = try await service.trust()
        let first = try #require(await service.serverIdentity(for: "example.com"))
        let cached = try #require(await service.serverIdentity(for: "EXAMPLE.COM"))
        #expect(first.certificateDER == cached.certificateDER)
        #expect(fixture.snapshot().keyCreates == 1)
        #expect(fixture.snapshot().installs == 1)
        #expect(fixture.snapshot().trusts == 1)
        fixture.revokeTrust()
        #expect(try await !service.status().trusted) // Explicit refresh invalidates a live lease.
        #expect(try await service.serverIdentity(for: "example.com") == nil)
    }

    @Test func concurrentCONNECTBurstSharesTrustCheckAndExpiredLeaseDetectsRevocation() async throws {
        let fixture = MemoryCertificates()
        let service = fixture.service()
        _ = try await service.generate()
        _ = try await service.install()
        _ = try await service.trust()
        let checksBefore = fixture.snapshot().trustChecks
        let readsBefore = fixture.snapshot().reads
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    let identity = try await service.serverIdentity(for: "example.com")
                    #expect(identity != nil)
                }
            }
            try await group.waitForAll()
        }
        #expect(fixture.snapshot().trustChecks - checksBefore == 1)
        #expect(fixture.snapshot().reads - readsBefore == 1)
        fixture.revokeTrust()
        fixture.advanceTime(6)
        #expect(try await service.serverIdentity(for: "example.com") == nil)
        #expect(fixture.snapshot().trustChecks - checksBefore == 2)
    }

    @Test func failedAuthorityRefreshNeverReusesPreviouslyTrustedLease() async throws {
        let fixture = MemoryCertificates()
        let service = fixture.service()
        _ = try await service.generate(); _ = try await service.install(); _ = try await service.trust()
        #expect(try await service.serverIdentity(for: "example.com") != nil)
        fixture.corruptDocument()
        await #expect(throws: LocalCertificateError.invalidCertificate) { try await service.status() }
        await #expect(throws: LocalCertificateError.invalidCertificate) { try await service.serverIdentity(for: "example.com") }
    }

    @Test(arguments: ["example.com", "127.0.0.1", "::1"])
    func leafIdentityHasMatchingKeySANAndBoundedValidity(host: String) throws {
        let key = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let root = try CertificateMaterial.root(privateKey: key, now: testDate)
        let expiration = testDate.addingTimeInterval(3600)
        let identity = try CertificateMaterial.serverIdentity(host: host, root: root, privateKey: key, now: testDate, expiresAt: expiration)
        let leaf = try Certificate(derEncoded: Array(identity.certificateDER))
        let leafKey = try P256.Signing.PrivateKey(pemRepresentation: String(decoding: identity.privateKeyPEM, as: UTF8.self))
        #expect(leaf.publicKey == Certificate.PrivateKey(leafKey).publicKey)
        #expect(root.publicKey.isValidSignature(leaf.signature, for: leaf))
        #expect(leaf.notValidAfter == expiration)
        #expect(try leaf.extensions.basicConstraints == .notCertificateAuthority)
        #expect(try leaf.extensions.extendedKeyUsage == ExtendedKeyUsage([.serverAuth]))
        let expected: GeneralName
        switch host {
        case "127.0.0.1": expected = .ipAddress(.init(contentBytes: [127, 0, 0, 1]))
        case "::1": expected = .ipAddress(.init(contentBytes: (Array(repeating: UInt8(0), count: 15) + [1])[...]))
        default: expected = .dnsName(host)
        }
        #expect(try leaf.extensions.subjectAlternativeNames == SubjectAlternativeNames([expected]))
    }

    @Test func expiredRootCannotIssueTLSIdentity() async throws {
        let key = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let data = try CertificateMaterial.data(CertificateMaterial.root(privateKey: key, now: testDate - 6 * 365 * 24 * 60 * 60))
        let fixture = MemoryCertificates(key: key, document: data, installed: data)
        #expect(try await fixture.service().serverIdentity(for: "example.com") == nil)
        #expect(fixture.snapshot().keyCreates == 0)
    }

    @Test func realSSLEvaluationRejectsAnUninstalledRoot() throws {
        let key = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let now = Date()
        let root = try CertificateMaterial.root(privateKey: key, now: now)
        let data = try CertificateMaterial.data(root)
        let probe = try CertificateMaterial.probe(root: root, privateKey: key, now: now)
        // Read-only evaluation: no certificate or trust settings are installed on this computer.
        #expect(try !KeychainCertificateStore().isTrusted(root: data, probe: probe))
    }
}

private let testDate = Date(timeIntervalSince1970: 1_790_294_400)

/// All mutable fixture state is guarded by its lock; no test invokes production Keychain writes.
private final class MemoryCertificates: CertificateKeyStore, CertificateDocumentStore, CertificateTrustStore, @unchecked Sendable {
    struct State {
        var key: Certificate.PrivateKey?
        var document: Data?
        var installed: Data?
        var trusted = false
        var needsAuthorization = false
        var cancelRepair = false
        var authorizationRepairs = 0
        var interactiveKeyReads = 0
        var removedCertificates: [Data] = []
        var cancelRemovalOnce: Bool
        var keyCreates = 0
        var installs = 0
        var trusts = 0
        var trustChecks = 0
        var reads = 0
        var date = testDate
        var cancelTrustOnce: Bool
        var trustTakesEffect: Bool
        var failWriteOnce: Bool
    }
    private let lock = NSLock()
    private var state: State

    init(key: Certificate.PrivateKey? = nil, document: Data? = nil, installed: Data? = nil,
         cancelTrustOnce: Bool = false, trustTakesEffect: Bool = true, failWriteOnce: Bool = false, cancelRemovalOnce: Bool = false) {
        state = State(key: key, document: document, installed: installed, cancelRemovalOnce: cancelRemovalOnce,
                      cancelTrustOnce: cancelTrustOnce, trustTakesEffect: trustTakesEffect, failWriteOnce: failWriteOnce)
    }

    func service() -> LocalCertificateService {
        LocalCertificateService(keyStore: self, documentStore: self, trustStore: self, now: { self.lock.withLock { self.state.date } })
    }

    func snapshot() -> State { lock.withLock { state } }
    func revokeTrust() { lock.withLock { state.trusted = false } }
    func advanceTime(_ seconds: TimeInterval) { lock.withLock { state.date += seconds } }
    func corruptDocument() { lock.withLock { state.document = Data([0, 1, 2]) } }
    func requireAuthorization(cancelRepair: Bool = false) {
        lock.withLock { state.needsAuthorization = true; state.cancelRepair = cancelRepair }
    }
    func authorizeSigning() throws {
        try lock.withLock {
            guard state.needsAuthorization else { return }
            var allowed = DarwinBoolean(false)
            #expect(SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess)
            guard allowed.boolValue else { throw LocalCertificateError.authorizationRequired }
            if state.cancelRepair { throw CancellationError() }
            state.needsAuthorization = false
            state.authorizationRepairs += 1
        }
    }
    func existingKey(certificate: Certificate?) throws -> Certificate.PrivateKey? {
        try lock.withLock {
            if state.needsAuthorization {
                var allowed = DarwinBoolean(false)
                #expect(SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess)
                if allowed.boolValue { state.interactiveKeyReads += 1 }
                throw LocalCertificateError.authorizationRequired
            }
            return state.key
        }
    }
    func createKey() -> Certificate.PrivateKey {
        lock.withLock {
            let key = Certificate.PrivateKey(P256.Signing.PrivateKey())
            state.key = key
            state.keyCreates += 1
            return key
        }
    }
    func read() -> Data? { lock.withLock { state.reads += 1; return state.document } }
    func write(_ data: Data) throws {
        try lock.withLock {
            if state.failWriteOnce {
                state.failWriteOnce = false
                throw CocoaError(.fileWriteUnknown)
            }
            state.document = data
        }
    }
    func remove() { lock.withLock { state.document = nil } }
    func remove(_ data: Data) throws {
        try lock.withLock {
            if state.cancelRemovalOnce {
                state.cancelRemovalOnce = false
                throw CancellationError()
            }
            state.removedCertificates.append(data)
            if state.installed == data { state.installed = nil; state.trusted = false }
        }
    }
    func installedCertificateData() -> Data? { lock.withLock { state.installed } }
    func isInstalled(_ data: Data) -> Bool { lock.withLock { state.installed == data } }
    func install(_ data: Data) { lock.withLock { state.installed = data; state.installs += 1 } }
    func isTrusted(root: Data, probe: Data) -> Bool { lock.withLock { state.trustChecks += 1; return state.trusted } }
    func trust(_ data: Data) throws {
        try lock.withLock {
            state.trusts += 1
            if state.cancelTrustOnce {
                state.cancelTrustOnce = false
                throw CancellationError()
            }
            state.trusted = state.trustTakesEffect
        }
    }
}
