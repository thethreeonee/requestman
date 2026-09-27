/// How clients are connected to the explicit proxy.
public enum CaptureMode: String, CaseIterable, Hashable, Sendable {
    case systemProxy
    case browser
    case proxyOnly

    public var title: String {
        switch self {
        case .systemProxy: "全局接管"
        case .browser: "仅启动浏览器"
        case .proxyOnly: "仅启动代理"
        }
    }
}
