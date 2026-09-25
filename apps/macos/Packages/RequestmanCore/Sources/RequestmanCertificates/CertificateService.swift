import Foundation

public struct CertificateStatus: Equatable, Sendable {
    public var generated: Bool
    public var installed: Bool
    public var trusted: Bool
    public var displayName: String
    public var fingerprint: String?
    public var expiresAt: Date?
    public var isExpired: Bool

    public init(
        generated: Bool = false, installed: Bool = false, trusted: Bool = false,
        displayName: String = "Requestman Local CA", fingerprint: String? = nil,
        expiresAt: Date? = nil, isExpired: Bool = false
    ) {
        self.generated = generated
        self.installed = installed
        self.trusted = trusted
        self.displayName = displayName
        self.fingerprint = fingerprint
        self.expiresAt = expiresAt
        self.isExpired = isExpired
    }

    public static let missing = CertificateStatus()
}

public protocol CertificateService: Sendable {
    func status() async throws -> CertificateStatus
    func generate() async throws -> CertificateStatus
    func install() async throws -> CertificateStatus
    func trust() async throws -> CertificateStatus
}

public enum LocalCertificateError: LocalizedError, Equatable {
    case authorizationRequired
    case privateKeyExportForbidden
    case security(operation: String, status: Int32)
    case invalidCertificate
    case missingPrivateKey
    case privateKeyMismatch
    case expiredCertificate
    case certificateNotGenerated
    case certificateNotInstalled
    case trustNotEffective
    case multipleCertificates

    public var errorDescription: String? {
        switch self {
        case .authorizationRequired: "HTTPS 证书需要重新授权。请在设置中点击“设置证书…”完成配置。"
        case .privateKeyExportForbidden: "不允许导出 HTTPS 调试 CA 私钥。"
        case let .security(operation, status): "\(operation)失败（\(status)）。请确认登录钥匙串已解锁后重试。"
        case .invalidCertificate: "本地证书已损坏或格式不符，未覆盖现有证书。请在钥匙串访问中检查 Requestman Local CA。"
        case .missingPrivateKey: "找不到此证书的私钥，未替换现有证书。请检查登录钥匙串中的 Requestman Local CA。"
        case .privateKeyMismatch: "证书与钥匙串中的私钥不匹配，未替换现有证书。请检查 Requestman Local CA。"
        case .expiredCertificate: "本地证书已过期，未自动替换。请在钥匙串访问中移除旧证书和对应私钥，并移走本地 requestman-root-ca.der 文件后重试。"
        case .certificateNotGenerated: "请先生成本地证书。"
        case .certificateNotInstalled: "请先安装本地证书。"
        case .trustNotEffective: "证书尚未获得有效的 SSL 信任。请重试，或在钥匙串访问中检查证书的信任设置。"
        case .multipleCertificates: "找到多个 Requestman Local CA 证书，未自动选择或替换。请先在钥匙串访问中检查。"
        }
    }
}
