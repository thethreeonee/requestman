import Foundation

public enum CaptureConfigurationError: Error, LocalizedError, Equatable {
    case noApplications
    case invalidProxyHost
    case invalidProxyPort

    public var errorDescription: String? {
        switch self {
        case .noApplications: "请至少选择一个目标应用。"
        case .invalidProxyHost: "请输入代理主机名或 IP 地址，不包含协议、路径或空格。"
        case .invalidProxyPort: "代理端口必须在 1–65535 之间。"
        }
    }
}
