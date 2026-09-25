import AppKit
import RequestmanCore

@MainActor
enum UpstreamProxyPrompt {
    static func choose(endpoint: ProxyEndpoint, reason: String, window: NSWindow?) async -> UpstreamFailureDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法连接上游代理"
        alert.informativeText = "无法连接 \(endpoint.host):\(endpoint.port)。\n\(reason)\n\n关闭上游后将使用系统路由；继续使用上游时，请求可能失败。"
        alert.addButton(withTitle: "关闭上游并启动")
        alert.addButton(withTitle: "继续使用上游")
        alert.addButton(withTitle: "取消启动").keyEquivalent = "\u{1b}"
        let response: NSApplication.ModalResponse
        if let window, window.isVisible {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = alert.runModal()
        }
        switch response {
        case .alertFirstButtonReturn: return .disableUpstream
        case .alertSecondButtonReturn: return .continueWithUpstream
        default: return .cancel
        }
    }
}
