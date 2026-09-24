enum WorkspaceSection: String, CaseIterable, Identifiable {
    case applications, requests, rules, connection

    var id: Self { self }

    var title: String {
        switch self {
        case .applications: "目标应用"
        case .requests: "请求"
        case .rules: "规则"
        case .connection: "连接"
        }
    }

    var symbol: String {
        switch self {
        case .applications: "app.connected.to.app.below.fill"
        case .requests: "network"
        case .rules: "slider.horizontal.3"
        case .connection: "point.3.connected.trianglepath.dotted"
        }
    }
}
