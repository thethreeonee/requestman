import Foundation

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case rules, requests
    var id: Self { self }
    var title: String {
        switch self { case .rules: "请求修改"; case .requests: "请求日志" }
    }
}
