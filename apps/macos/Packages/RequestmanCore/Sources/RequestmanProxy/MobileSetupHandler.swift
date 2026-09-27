import Foundation
import NIOCore
import NIOHTTP1
import RequestmanCore
import RequestmanCertificates

/// Local onboarding responses never enter capture/rules or the upstream proxy.
final class MobileSetupHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    private let configuration: ExplicitProxyConfiguration
    private let certificateProvider: (any TLSCertificateProviding)?
    private var request: HTTPRequestHead?
    private var task: Task<Void, Never>?
    private var serving = false

    init(configuration: ExplicitProxyConfiguration, certificateProvider: (any TLSCertificateProviding)?) {
        self.configuration = configuration
        self.certificateProvider = certificateProvider
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        if case .head(let head) = part, !serving,
           head.method == .CONNECT || !head.headers["upgrade"].isEmpty {
            // Leave before decoder removal forwards raw TLS/WebSocket bytes.
            context.fireChannelRead(data)
            context.pipeline.removeHandler(self, promise: nil)
            return
        }
        if case .head(let head) = part, !serving, isSetupRequest(head) {
            serving = true
            request = head
        }
        guard serving else { context.fireChannelRead(data); return }
        if case .end = part, let head = request {
            request = nil
            let channel = context.channel
            let provider = certificateProvider
            task = Task {
                let response: MobileSetupResponse
                do {
                    let path = URLComponents(string: head.uri)?.path ?? ""
                    let certificate = path == "/requestman/ca.cer" || path == "/requestman/ios.mobileconfig"
                        ? try await provider?.publicCertificateDER() : nil
                    response = try MobileSetupResponse.make(method: head.method.rawValue, path: path, certificate: certificate)
                } catch {
                    response = .text(503, "证书暂不可用，请在 Mac 的 Requestman 设置中完成 HTTPS 证书配置后重试。")
                }
                guard !Task.isCancelled else { return }
                channel.eventLoop.execute {
                    guard channel.isActive else { return }
                    var headers = HTTPHeaders([
                        ("Content-Type", response.contentType), ("Content-Length", String(response.body.count)),
                        ("Connection", "close"), ("Cache-Control", "no-store"), ("X-Content-Type-Options", "nosniff")
                    ])
                    if let filename = response.filename { headers.add(name: "Content-Disposition", value: "attachment; filename=\"\(filename)\"") }
                    channel.write(HTTPServerResponsePart.head(.init(version: .http1_1, status: .init(statusCode: response.status), headers: headers)), promise: nil)
                    if head.method != .HEAD {
                        channel.write(HTTPServerResponsePart.body(.byteBuffer(channel.allocator.buffer(bytes: response.body))), promise: nil)
                    }
                    channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in channel.close(promise: nil) }
                }
            }
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        if serving { if request != nil { context.read() } }
        else { context.fireChannelReadComplete() }
    }
    func channelInactive(context: ChannelHandlerContext) {
        task?.cancel()
        context.fireChannelInactive()
    }

    private func isSetupRequest(_ head: HTTPRequestHead) -> Bool {
        guard configuration.allowLAN, head.method != .CONNECT else { return false }
        let url = URLComponents(string: head.uri)
        guard let path = url?.path, path == "/requestman" || path.hasPrefix("/requestman/") else { return false }
        let authority = head.uri.hasPrefix("/")
            ? (head.headers["host"].count == 1 ? URLComponents(string: "http://" + head.headers["host"][0]) : nil)
            : url
        guard let authority, authority.scheme == "http", let host = authority.host,
              authority.user == nil, authority.password == nil,
              authority.port == configuration.port, LocalNetwork.isLocalHost(host) else { return false }
        return true
    }
}

struct MobileSetupResponse: Sendable {
    var status: Int
    var contentType: String
    var body: Data
    var filename: String?

    static func text(_ status: Int, _ text: String) -> Self {
        .init(status: status, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
    }
    static func make(method: String, path: String, certificate: Data?) throws -> Self {
        guard method == "GET" || method == "HEAD" else { return .text(405, "请使用 GET 下载证书。") }
        switch path {
        case "/requestman", "/requestman/":
            return .init(status: 200, contentType: "text/html; charset=utf-8", body: Data(page.utf8))
        case "/requestman/ca.cer", "/requestman/ios.mobileconfig":
            guard let certificate else { return .text(503, "请先在 Mac 的 Requestman 设置中点击“设置证书…”完成配置，再重新下载。") }
            if path.hasSuffix(".cer") {
                return .init(status: 200, contentType: "application/pkix-cert", body: certificate, filename: "requestman-ca.cer")
            }
            let profile: [String: Any] = [
                "PayloadType": "Configuration", "PayloadVersion": 1,
                "PayloadIdentifier": "app.requestman.ca", "PayloadUUID": UUID().uuidString,
                "PayloadDisplayName": "Requestman HTTPS 调试证书",
                "PayloadContent": [[
                    "PayloadType": "com.apple.security.root", "PayloadVersion": 1,
                    "PayloadIdentifier": "app.requestman.ca.root", "PayloadUUID": UUID().uuidString,
                    "PayloadDisplayName": "Requestman Local CA", "PayloadContent": certificate
                ]]
            ]
            return .init(status: 200, contentType: "application/x-apple-aspen-config",
                         body: try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0),
                         filename: "requestman.mobileconfig")
        default: return .text(404, "未找到此页面。")
        }
    }

    private static let page = """
    <!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>连接 Requestman</title><style>body{font:17px system-ui;line-height:1.7;max-width:640px;margin:32px auto;padding:0 20px}a{display:inline-block;margin:8px 0}code{overflow-wrap:anywhere}</style>
    <h1>连接 Requestman</h1><p>此页面已连通 Mac。请保持手机与 Mac 位于可互通的局域网，并保持 Requestman 捕获运行。</p>
    <h2>1. 设置 Wi-Fi 代理</h2><p>在当前 Wi-Fi 的手动代理设置中，服务器填写本页地址中的 IP，端口填写地址中冒号后的数字（默认 9090）。不要填写 http:// 或路径。</p>
    <h2>2. 安装 HTTPS 证书</h2><h3>iPhone / iPad</h3>
    <a href="/requestman/ios.mobileconfig">下载 iPhone 证书描述文件</a>
    <p>使用 Safari 下载。在“设置 → 通用 → VPN 与设备管理”中安装描述文件，然后前往“设置 → 通用 → 关于本机 → 证书信任设置”，为 Requestman Local CA 开启完全信任。</p>
    <h3>Android</h3><a href="/requestman/ca.cer">下载 Android CA 证书</a>
    <p>在系统设置中搜索“安装证书”，选择 CA 证书并安装下载的文件。不同厂商的入口可能不同。目标为 Android 7.0 及以上的 App 默认不信任用户 CA；自己开发的 App 可通过 Network Security Configuration 的 debug-overrides 配置调试 CA。</p>
    <h2>3. 查看请求</h2><p>打开网页或被调试 App，在 Mac 的请求日志查看设备来源。点击设备来源可设置别名。手机请求使用 Mac 中配置的同一上游代理。</p>
    <p>仅捕获经过 HTTP 代理的流量。证书绑定或忽略代理的 App 无法保证解密；当前不支持 HTTP/2 内容处理、HTTP/3 或 UDP 抓取。使用结束后将 Wi-Fi 代理恢复为关闭。</p></html>
    """
}
