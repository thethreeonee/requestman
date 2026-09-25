/// How clients are connected to the explicit loopback proxy.
public enum CaptureMode: String, CaseIterable, Hashable, Sendable {
    case systemProxy
    case browser

    public var title: String {
        switch self {
        case .systemProxy: "全局接管"
        case .browser: "仅启动浏览器"
        }
    }
}
