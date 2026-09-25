import Foundation
import Security
import X509

/// Uses the user's default file-based keychain (normally login), matching the app's current signing setup.
/// The private key is nonextractable and protected by that keychain's lock and access-control list.
/// kSecAttrAccessible only applies to the Data Protection keychain on macOS and is not claimed here.
struct KeychainCertificateStore: CertificateKeyStore, CertificateTrustStore {
    private static let keyTag = Data("com.requestman.local-ca.p256.v1".utf8)

    func existingKey() throws -> Certificate.PrivateKey? {
        var result: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag as String: Self.keyTag,
            kSecMatchSearchList as String: [try defaultKeychain()],
            kSecUseDataProtectionKeychain as String: false,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status, operation: "读取证书私钥")
        guard let keys = result as? [SecKey], keys.count == 1, let key = keys.first else {
            throw LocalCertificateError.multipleCertificates
        }
        return try Certificate.PrivateKey(key)
    }

    func createKey() throws -> Certificate.PrivateKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecUseKeychain as String: try defaultKeychain(),
            kSecUseDataProtectionKeychain as String: false,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrIsExtractable as String: false,
                kSecAttrApplicationTag as String: Self.keyTag,
                kSecAttrLabel as String: CertificateMaterial.displayName,
                kSecAttrCanSign as String: true,
                kSecAttrCanDecrypt as String: false,
                kSecAttrCanDerive as String: false
            ]
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let code = error.map { Int32(CFErrorGetCode($0.takeRetainedValue())) } ?? errSecInternalError
            try check(code, operation: "生成证书私钥")
            throw LocalCertificateError.missingPrivateKey
        }
        return try Certificate.PrivateKey(key)
    }

    func installedCertificateData() throws -> Data? {
        // Match the certificate subject, not a mutable Keychain display label.
        let candidates = try certificates().filter { data in
            guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else { return false }
            return SecCertificateCopySubjectSummary(certificate) as String? == CertificateMaterial.displayName
        }
        guard candidates.count <= 1 else { throw LocalCertificateError.multipleCertificates }
        return candidates.first
    }

    func isInstalled(_ data: Data) throws -> Bool {
        try certificates().contains(data)
    }

    func install(_ data: Data) throws {
        let certificate = try certificate(data)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: CertificateMaterial.displayName,
            kSecUseKeychain as String: try defaultKeychain(),
            kSecUseDataProtectionKeychain as String: false
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecDuplicateItem { try check(status, operation: "安装证书") }
    }

    func isTrusted(root: Data, probe: Data) throws -> Bool {
        var trust: SecTrust?
        try check(
            SecTrustCreateWithCertificates(
                [try certificate(probe), try certificate(root)] as CFArray,
                SecPolicyCreateSSL(true, CertificateMaterial.probeHost as CFString), &trust
            ), operation: "检查证书信任"
        )
        guard let trust else { throw LocalCertificateError.trustNotEffective }
        try check(SecTrustSetNetworkFetchAllowed(trust, false), operation: "检查证书信任")
        // Deliberately do not call SecTrustSetAnchorCertificates: only actual system/user trust counts.
        return SecTrustEvaluateWithError(trust, nil)
    }

    func trust(_ data: Data) throws {
        let certificate = try certificate(data)
        var previous: CFArray?
        let status = SecTrustSettingsCopyTrustSettings(certificate, .user, &previous)
        if status != errSecItemNotFound { try check(status, operation: "读取证书信任设置") }
        let previousSettings = previous as? [[String: Any]] ?? []
        // Preserve other policy-specific choices and unrestricted constraints made by the user.
        // A conflicting broad deny is reported by the subsequent real trust evaluation.
        var settings = previousSettings.filter { entry in
            guard let value = entry[kSecTrustSettingsPolicy as String],
                  CFGetTypeID(value as CFTypeRef) == SecPolicyGetTypeID() else { return true }
            let policy = value as! SecPolicy
            guard let copiedProperties = SecPolicyCopyProperties(policy) else { return true }
            let properties = copiedProperties as NSDictionary
            return properties[kSecPolicyOid] as? String != kSecPolicyAppleSSL as String
        }
        settings.append([
            kSecTrustSettingsPolicy as String: SecPolicyCreateSSL(true, nil),
            kSecTrustSettingsResult as String: SecTrustSettingsResult.trustRoot.rawValue
        ])
        // This call presents macOS's authentication UI. It must never run on MainActor.
        try check(SecTrustSettingsSetTrustSettings(certificate, .user, settings as CFArray), operation: "信任证书")
    }

    private func certificates() throws -> [Data] {
        var result: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecMatchSearchList as String: [try defaultKeychain()],
            kSecUseDataProtectionKeychain as String: false,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnData as String: true
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try check(status, operation: "读取已安装证书")
        guard let certificates = result as? [Data] else { throw LocalCertificateError.invalidCertificate }
        return certificates
    }

    private func defaultKeychain() throws -> SecKeychain {
        var keychain: SecKeychain?
        try check(SecKeychainCopyDefault(&keychain), operation: "打开登录钥匙串")
        guard let keychain else { throw LocalCertificateError.missingPrivateKey }
        return keychain
    }

    private func certificate(_ data: Data) throws -> SecCertificate {
        guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
            throw LocalCertificateError.invalidCertificate
        }
        return certificate
    }

    private func check(_ status: OSStatus, operation: String) throws {
        if status == errSecUserCanceled || status == errAuthorizationCanceled { throw CancellationError() }
        guard status == errSecSuccess else {
            throw LocalCertificateError.security(operation: operation, status: status)
        }
    }
}
