import Foundation
import X509

protocol CertificateKeyStore: Sendable {
    func existingKey(certificate: Certificate?) throws -> Certificate.PrivateKey?
    func authorizeSigning() throws
    func createKey() throws -> Certificate.PrivateKey
}

protocol CertificateDocumentStore: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func remove() throws
}

protocol CertificateTrustStore: Sendable {
    func installedCertificateData() throws -> Data?
    func isInstalled(_ data: Data) throws -> Bool
    func install(_ data: Data) throws
    func isTrusted(root: Data, probe: Data) throws -> Bool
    func trust(_ data: Data) throws
    func remove(_ data: Data) throws
}

/// All filesystem, cryptography, Keychain and blocking trust authorization work stays off MainActor.
public actor LocalCertificateService: CertificateService, TLSCertificateProviding {
    private let keyStore: any CertificateKeyStore
    private let documentStore: any CertificateDocumentStore
    private let trustStore: any CertificateTrustStore
    private let now: @Sendable () -> Date

    private struct CachedLeaf {
        let identity: TLSCertificateIdentity
        let rootFingerprint: String
        let expiresAt: Date
    }
    private var leaves: [String: CachedLeaf] = [:]
    // A burst of CONNECTs must not serialize repeated Keychain I/O and probe signing.
    // Explicit status/setup operations invalidate this short lease; never extend on a hit.
    private struct AuthorityLease {
        let identity: Identity?
        let checkedAt: Date
        let expiresAt: Date
    }
    private var authorityLease: AuthorityLease?

    public func serverIdentity(for host: String) throws -> TLSCertificateIdentity? {
        return try CertificateKeychainInteraction.perform(allowingUI: false) {
            try Task.checkCancellation()
            guard let root = try trustedIdentity() else { return nil }
            let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let fingerprint = CertificateMaterial.fingerprint(root.data)
            if let cached = leaves[name], cached.rootFingerprint == fingerprint, cached.expiresAt > now() {
                return cached.identity
            }
            let expiresAt = min(now().addingTimeInterval(7 * 24 * 60 * 60), root.certificate.notValidAfter)
            let leaf = try CertificateMaterial.serverIdentity(
                host: name, root: root.certificate, privateKey: root.privateKey, now: now(), expiresAt: expiresAt
            )
            leaves = leaves.filter { $0.value.expiresAt > now() && $0.value.rootFingerprint == fingerprint }
            if leaves.count >= 128, let key = leaves.keys.sorted().first { leaves.removeValue(forKey: key) }
            leaves[name] = CachedLeaf(identity: leaf, rootFingerprint: fingerprint, expiresAt: expiresAt)
            return leaf
        }
    }

    public init(directoryURL: URL) {
        keyStore = KeychainCertificateStore()
        documentStore = FileCertificateDocumentStore(directoryURL: directoryURL)
        trustStore = KeychainCertificateStore()
        now = { Date() }
    }

    init(
        keyStore: any CertificateKeyStore, documentStore: any CertificateDocumentStore,
        trustStore: any CertificateTrustStore, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.keyStore = keyStore
        self.documentStore = documentStore
        self.trustStore = trustStore
        self.now = now
    }

    public func status() throws -> CertificateStatus {
        return try CertificateKeychainInteraction.perform(allowingUI: false) {
            authorityLease = nil
            guard let identity = try loadIdentity() else { return .missing }
            let result = try status(identity)
            cacheAuthority(result.trusted ? identity : nil)
            return result
        }
    }

    /// Repairs access to an existing CA only. Never generates, installs or trusts a CA.
    public func migrateAuthorization(allowingUI: Bool) throws -> CertificateStatus {
        do { return try status() }
        catch LocalCertificateError.authorizationRequired { }
        return try CertificateKeychainInteraction.perform(allowingUI: allowingUI) {
            try Task.checkCancellation()
            guard let data = try documentStore.read() ?? trustStore.installedCertificateData() else {
                throw LocalCertificateError.certificateNotGenerated
            }
            try requireValidDate(CertificateMaterial.decodeRoot(data))
            try keyStore.authorizeSigning()
            return try status() // Success requires a fresh, noninteractive signing/trust check.
        }
    }

    public func generate() throws -> CertificateStatus {
        return try CertificateKeychainInteraction.perform(allowingUI: true) {
            authorityLease = nil
            try Task.checkCancellation()
            if let data = try documentStore.read() ?? trustStore.installedCertificateData() {
                try requireValidDate(CertificateMaterial.decodeRoot(data))
            }
            try keyStore.authorizeSigning()
            if let identity = try loadIdentity() {
                try requireValidDate(identity.certificate)
                // Recover a missing public DER file from the matching installed certificate.
                if try documentStore.read() == nil { try documentStore.write(identity.data) }
                return try status(identity)
            }
            // Reuse a key left by an interrupted first attempt; never silently replace a key or CA.
            let privateKey = try keyStore.existingKey(certificate: nil) ?? keyStore.createKey()
            let certificate = try CertificateMaterial.root(privateKey: privateKey, now: now())
            let data = try CertificateMaterial.data(certificate)
            try documentStore.write(data)
            return try status(Identity(certificate: certificate, privateKey: privateKey, data: data))
        }
    }

    /// Explicit recovery after the user deleted the key. Never rotate a surviving key,
    /// and never interpret a locked keychain or an authorization failure as a missing key.
    public func regenerate() throws -> CertificateStatus {
        try CertificateKeychainInteraction.perform(allowingUI: true) {
            authorityLease = nil
            leaves.removeAll()
            try Task.checkCancellation()
            guard let data = try documentStore.read() ?? trustStore.installedCertificateData() else {
                return try generate()
            }
            let certificate = try CertificateMaterial.decodeRoot(data)
            guard try keyStore.existingKey(certificate: certificate) == nil else {
                return try generate() // State may have been repaired since the UI offered recovery.
            }
            if let installed = try trustStore.installedCertificateData(), installed != data {
                throw LocalCertificateError.multipleCertificates
            }
            // Remove only the orphaned CA. Clear its public file before creating a key,
            // so interruption/save failure resumes as the existing orphan-key recovery path.
            try trustStore.remove(data)
            try documentStore.remove()
            try Task.checkCancellation()
            return try generate()
        }
    }

    public func install() throws -> CertificateStatus {
        return try CertificateKeychainInteraction.perform(allowingUI: true) {
            authorityLease = nil
            try Task.checkCancellation()
            let identity = try requireIdentity()
            try requireValidDate(identity.certificate)
            if try !trustStore.isInstalled(identity.data) { try trustStore.install(identity.data) }
            let result = try status(identity)
            guard result.installed else { throw LocalCertificateError.certificateNotInstalled }
            return result
        }
    }

    public func trust() throws -> CertificateStatus {
        return try CertificateKeychainInteraction.perform(allowingUI: true) {
            authorityLease = nil
            try Task.checkCancellation()
            let identity = try requireIdentity()
            try requireValidDate(identity.certificate)
            let current = try status(identity)
            guard current.installed else { throw LocalCertificateError.certificateNotInstalled }
            if current.trusted { return current }
            try trustStore.trust(identity.data)
            let result = try status(identity)
            guard result.trusted else { throw LocalCertificateError.trustNotEffective }
            return result
        }
    }

    private struct Identity {
        let certificate: Certificate
        let privateKey: Certificate.PrivateKey
        let data: Data
    }

    private func trustedIdentity() throws -> Identity? {
        let date = now()
        if let lease = authorityLease, date >= lease.checkedAt, date < lease.expiresAt {
            return lease.identity
        }
        authorityLease = nil // A failed refresh must not keep the previous trusted identity.
        guard let identity = try loadIdentity(), try status(identity).trusted else {
            cacheAuthority(nil)
            return nil
        }
        cacheAuthority(identity)
        return identity
    }

    private func cacheAuthority(_ identity: Identity?) {
        let date = now()
        authorityLease = AuthorityLease(identity: identity, checkedAt: date,
            expiresAt: min(date.addingTimeInterval(5), identity?.certificate.notValidAfter ?? .distantFuture))
        if identity == nil { leaves.removeAll() }
    }

    private func loadIdentity() throws -> Identity? {
        guard let data = try documentStore.read() ?? trustStore.installedCertificateData() else { return nil }
        let publicCertificate = try CertificateMaterial.decodeRoot(data)
        guard let privateKey = try keyStore.existingKey(certificate: publicCertificate) else { throw LocalCertificateError.missingPrivateKey }
        let certificate = try CertificateMaterial.decodeRoot(data, privateKey: privateKey)
        return Identity(certificate: certificate, privateKey: privateKey, data: data)
    }

    private func requireIdentity() throws -> Identity {
        guard let identity = try loadIdentity() else { throw LocalCertificateError.certificateNotGenerated }
        return identity
    }

    private func requireValidDate(_ certificate: Certificate) throws {
        guard certificate.notValidAfter > now(), certificate.notValidBefore <= now() else {
            throw LocalCertificateError.expiredCertificate
        }
    }

    private func status(_ identity: Identity) throws -> CertificateStatus {
        let expired = identity.certificate.notValidAfter <= now() || identity.certificate.notValidBefore > now()
        let installed = try trustStore.isInstalled(identity.data)
        let trusted: Bool
        if installed && !expired {
            let probe = try CertificateMaterial.probe(root: identity.certificate, privateKey: identity.privateKey, now: now())
            trusted = try trustStore.isTrusted(root: identity.data, probe: probe)
        } else { trusted = false }
        return CertificateStatus(
            generated: true, installed: installed, trusted: trusted,
            displayName: CertificateMaterial.displayName, fingerprint: CertificateMaterial.fingerprint(identity.data),
            expiresAt: identity.certificate.notValidAfter, isExpired: expired
        )
    }
}

struct FileCertificateDocumentStore: CertificateDocumentStore {
    let directoryURL: URL
    private var certificateURL: URL { directoryURL.appendingPathComponent("requestman-root-ca.der") }

    func read() throws -> Data? {
        guard FileManager.default.fileExists(atPath: certificateURL.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: certificateURL.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 1_048_576 else {
            throw LocalCertificateError.invalidCertificate
        }
        return try Data(contentsOf: certificateURL)
    }

    func write(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: certificateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: certificateURL.path)
    }

    func remove() throws {
        guard FileManager.default.fileExists(atPath: certificateURL.path) else { return }
        try FileManager.default.trashItem(at: certificateURL, resultingItemURL: nil)
    }
}
