import Foundation

/// A short-lived leaf identity. The root signing key never leaves the Keychain.
public struct TLSCertificateIdentity: Sendable {
    public let certificateDER: Data
    public let privateKeyPEM: Data

    public init(certificateDER: Data, privateKeyPEM: Data) {
        self.certificateDER = certificateDER
        self.privateKeyPEM = privateKeyPEM
    }
}

public protocol TLSCertificateProviding: Sendable {
    /// nil means certificate setup is incomplete; capture may continue as an opaque tunnel.
    func serverIdentity(for host: String) async throws -> TLSCertificateIdentity?
    /// Public root only. This read must never create material or request authorization.
    func publicCertificateDER() async throws -> Data?
}

public extension TLSCertificateProviding {
    func publicCertificateDER() async throws -> Data? { nil }
}
