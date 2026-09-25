import Foundation
import Security
import SwiftASN1
import X509

/// Uses the public certificate's key, avoiding SecKeyCopyPublicKey and its legacy
/// key export authorization. The CA private key is only ever used for signing.
/// The SecKey handle is immutable; its signing operations share the interaction lock.
struct KeychainSigningKey: CustomPrivateKey, @unchecked Sendable {
    let key: SecKey
    let publicKey: Certificate.PublicKey
    static let defaultPEMDiscriminator = "PRIVATE KEY"
    var defaultSignatureAlgorithm: Certificate.SignatureAlgorithm { .ecdsaWithSHA256 }
    var supportedSignatureAlgorithms: [Certificate.SignatureAlgorithm] { [.ecdsaWithSHA256] }

    func signSynchronously(bytes: some DataProtocol,
                           signatureAlgorithm: Certificate.SignatureAlgorithm) throws -> Certificate.Signature {
        guard signatureAlgorithm == .ecdsaWithSHA256 else {
            throw LocalCertificateError.invalidCertificate
        }
        // Also guard the key itself so no caller can accidentally sign interactively.
        return try CertificateKeychainInteraction.perform(allowingUI: false) {
            var error: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256,
                                                       Data(bytes) as CFData, &error) as Data? else {
                let status = error.map { OSStatus(CFErrorGetCode($0.takeRetainedValue())) } ?? errSecInternalError
                if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
                    throw LocalCertificateError.authorizationRequired
                }
                throw LocalCertificateError.security(operation: "签发 HTTPS 证书", status: status)
            }
            return try Certificate.Signature(signatureAlgorithm: signatureAlgorithm,
                                             signatureBytes: ASN1BitString(bytes: Array(signature)[...]))
        }
    }

    func serialize(into coder: inout DER.Serializer) throws {
        throw LocalCertificateError.privateKeyExportForbidden
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        CFEqual(lhs.key, rhs.key) && lhs.publicKey == rhs.publicKey
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(key))
        hasher.combine(publicKey)
    }
}
