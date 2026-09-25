import CryptoKit
import Darwin
import Foundation
import Security
import X509

enum CertificateMaterial {
    static let displayName = "Requestman Local CA"
    static let probeHost = "requestman.invalid"

    static func root(privateKey: Certificate.PrivateKey, now: Date) throws -> Certificate {
        let name = try DistinguishedName {
            OrganizationName("Requestman")
            CommonName(displayName)
        }
        return try Certificate(
            version: .v3, serialNumber: .init(), publicKey: privateKey.publicKey,
            notValidBefore: now.addingTimeInterval(-300),
            notValidAfter: now.addingTimeInterval(5 * 365 * 24 * 60 * 60),
            issuer: name, subject: name, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
                SubjectKeyIdentifier(hash: privateKey.publicKey)
            },
            issuerPrivateKey: privateKey
        )
    }

    static func decodeRoot(_ data: Data, privateKey: Certificate.PrivateKey) throws -> Certificate {
        let certificate: Certificate
        do { certificate = try Certificate(derEncoded: Array(data)) }
        catch { throw LocalCertificateError.invalidCertificate }
        guard certificate.subject == certificate.issuer,
              certificate.publicKey.isValidSignature(certificate.signature, for: certificate),
              certificate.signatureAlgorithm == .ecdsaWithSHA256,
              try certificate.extensions.basicConstraints == .isCertificateAuthority(maxPathLength: 0),
              try certificate.extensions.keyUsage == KeyUsage(keyCertSign: true, cRLSign: true),
              certificate.extensions[oid: .X509ExtensionID.basicConstraints]?.critical == true,
              certificate.extensions[oid: .X509ExtensionID.keyUsage]?.critical == true
        else { throw LocalCertificateError.invalidCertificate }
        guard certificate.publicKey == privateKey.publicKey else {
            throw LocalCertificateError.privateKeyMismatch
        }
        return certificate
    }

    static func data(_ certificate: Certificate) throws -> Data {
        SecCertificateCopyData(try SecCertificate.makeWithCertificate(certificate)) as Data
    }

    /// This probe proves SSL trust through the real system/user anchor set. It is never persisted.
    static func probe(root: Certificate, privateKey: Certificate.PrivateKey, now: Date) throws -> Data {
        let leafKey = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let leaf = try Certificate(
            version: .v3, serialNumber: .init(), publicKey: leafKey.publicKey,
            notValidBefore: now.addingTimeInterval(-60), notValidAfter: now.addingTimeInterval(300),
            issuer: root.subject, subject: try DistinguishedName { CommonName(probeHost) },
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames([.dnsName(probeHost)])
                AuthorityKeyIdentifier(keyIdentifier: SubjectKeyIdentifier(hash: root.publicKey).keyIdentifier)
            },
            issuerPrivateKey: privateKey
        )
        return try data(leaf)
    }

    static func serverIdentity(
        host: String, root: Certificate, privateKey: Certificate.PrivateKey, now: Date, expiresAt: Date
    ) throws -> TLSCertificateIdentity {
        guard !host.isEmpty, host.utf8.count <= 253,
              !host.contains(where: { $0.isWhitespace || $0 == "\\" || $0 == "/" || $0 == "*" }),
              host.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 }) else {
            throw LocalCertificateError.invalidCertificate
        }
        let key = P256.Signing.PrivateKey()
        let leafKey = Certificate.PrivateKey(key)
        var address = [UInt8](repeating: 0, count: 16)
        let alternativeName: GeneralName
        if inet_pton(AF_INET, host, &address) == 1 {
            alternativeName = .ipAddress(.init(contentBytes: Array(address.prefix(4))[...]))
        } else if inet_pton(AF_INET6, host, &address) == 1 {
            alternativeName = .ipAddress(.init(contentBytes: address[...]))
        } else {
            guard host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }) else {
                throw LocalCertificateError.invalidCertificate
            }
            alternativeName = .dnsName(host)
        }
        let leaf = try Certificate(
            version: .v3, serialNumber: .init(), publicKey: leafKey.publicKey,
            notValidBefore: max(now.addingTimeInterval(-60), root.notValidBefore), notValidAfter: expiresAt,
            issuer: root.subject, subject: try DistinguishedName { CommonName(host) },
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames([alternativeName])
                AuthorityKeyIdentifier(keyIdentifier: SubjectKeyIdentifier(hash: root.publicKey).keyIdentifier)
            },
            issuerPrivateKey: privateKey
        )
        return try TLSCertificateIdentity(certificateDER: data(leaf), privateKeyPEM: Data(key.pemRepresentation.utf8))
    }

    static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
