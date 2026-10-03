import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import RequestmanCore

/// A rule-free HTTP/1.1 origin transport. The owner supplies its immutable route and cancellation state.
enum ProxyHTTPServiceTransport {
    struct Target: Sendable {
        let url: URL
        let host: String
        let port: Int
        let secure: Bool
        let authority: String
        let path: String

        init(_ value: String, listenerPort: Int) throws {
            guard let parts = URLComponents(string: value), let url = parts.url,
                  ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
                  let rawHost = parts.host, !rawHost.isEmpty, parts.user == nil, parts.password == nil,
                  !value.utf8.contains(where: { $0 < 32 || $0 == 127 }) else {
                throw WorkflowError.invalid("fetch 需要有效的 HTTP 或 HTTPS URL")
            }
            host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            secure = parts.scheme?.lowercased() == "https"
            port = parts.port ?? (secure ? 443 : 80)
            guard (1...65535).contains(port), !(port == listenerPort && LocalNetwork.isLocalHost(host)) else {
                throw WorkflowError.invalid("fetch 目标无效或会形成代理循环")
            }
            var withoutFragment = parts; withoutFragment.fragment = nil
            self.url = withoutFragment.url ?? url
            let wireHost = host.contains(":") ? "[\(host)]" : host
            authority = wireHost + ":\(port)"
            path = (parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath)
                + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
        }
        var origin: String { "\(secure ? "https" : "http")://\(host.lowercased()):\(port)" }
    }

    static func connect(target: Target, configuration: ExplicitProxyConfiguration,
                        shared: ProxySharedState, eventLoop: any EventLoop,
                        attach: @escaping @Sendable (Channel) -> Void,
                        cancelled: @escaping @Sendable () -> Bool) -> EventLoopFuture<Channel> {
        let endpoint: ProxyEndpoint
        if case .httpProxy(let proxy) = configuration.upstream { endpoint = proxy }
        else { endpoint = ProxyEndpoint(host: target.host, port: target.port) }
        guard !(endpoint.port == configuration.port && LocalNetwork.isLocalHost(endpoint.host)) else {
            return eventLoop.makeFailedFuture(WorkflowError.invalid("fetch 出口指向本地代理"))
        }
        return ClientBootstrap(group: eventLoop).connectTimeout(.seconds(5))
            .channelOption(ChannelOptions.autoRead, value: false)
            .channelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .channelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 16_384))
            .channelInitializer { channel in
                guard shared.register(channel, downstream: false), !cancelled() else { return channel.close() }
                attach(channel)
                return channel.eventLoop.makeSucceededVoidFuture()
            }.connect(host: endpoint.host, port: endpoint.port).flatMap { channel in
                guard !cancelled(), !shared.isStopping,
                      !(channel.remoteAddress?.port == configuration.port
                        && LocalNetwork.isLocalHost(channel.remoteAddress?.ipAddress ?? "")) else {
                    closeProxyChannel(channel)
                    return eventLoop.makeFailedFuture(WorkflowError.invalid("fetch 已取消或目标解析后指向代理自身"))
                }
                let tunnel: EventLoopFuture<Void>
                if target.secure, case .httpProxy = configuration.upstream {
                    let ready = eventLoop.makePromise(of: Void.self)
                    let timeout = eventLoop.scheduleTask(in: .seconds(30)) {
                        closeProxyChannel(channel)
                    }
                    tunnel = channel.pipeline.addHTTPClientHandlers(leftOverBytesStrategy: .forwardBytes,
                        decoderLimitConfiguration: proxyDecoderLimits()).flatMap {
                        channel.pipeline.addHandler(TunnelHandshake(ready: ready))
                    }.flatMap {
                        let headers = HTTPHeaders([("Host", target.authority)])
                        channel.write(HTTPClientRequestPart.head(HTTPRequestHead(version: .http1_1,
                            method: .CONNECT, uri: target.authority, headers: headers)), promise: nil)
                        channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
                        channel.read()
                        return ready.futureResult
                    }
                    tunnel.whenComplete { _ in timeout.cancel() }
                } else { tunnel = eventLoop.makeSucceededVoidFuture() }
                return tunnel.flatMap {
                    guard !cancelled() else { return eventLoop.makeFailedFuture(WorkflowError.invalid("fetch 已取消")) }
                    if target.secure {
                        return ProxyTLS.negotiateClient(channel: channel, host: target.host, http2: false,
                            shared: shared) { eventLoop.makeSucceededFuture(channel) }
                    }
                    return eventLoop.makeSucceededFuture(channel)
                }.flatMapError { error in
                    closeProxyChannel(channel)
                    return eventLoop.makeFailedFuture(error)
                }
            }
    }

    static func requestHead(_ request: ScriptHTTPRequest, target: Target,
                            route: UpstreamRoute) throws -> HTTPRequestHead {
        guard HTTPMessageValidation.isToken(request.method),
              !["CONNECT", "TRACE", "TRACK"].contains(request.method.uppercased()),
              !(request.body != nil && ["GET", "HEAD"].contains(request.method.uppercased())) else {
            throw WorkflowError.invalid("fetch 请求方法或 Body 无效")
        }
        for field in request.headers {
            guard HTTPMessageValidation.isToken(field.name),
                  !field.value.utf8.contains(where: { $0 < 32 && $0 != 9 || $0 == 127 }) else {
                throw WorkflowError.invalid("fetch Header 无效")
            }
        }
        let connectionTokens = request.headers.filter { $0.name.lowercased() == "connection" }
            .flatMap { $0.value.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        let maintained = Set(connectionTokens + ["host", "connection", "proxy-connection", "proxy-authorization",
            "proxy-authenticate", "content-length", "transfer-encoding", "keep-alive", "te", "trailer", "upgrade", "expect"])
        var headers = HTTPHeaders(request.headers.filter { !maintained.contains($0.name.lowercased()) }.map { ($0.name, $0.value) })
        let host = target.host.contains(":") ? "[\(target.host)]" : target.host
        headers.add(name: "Host", value: host + ((target.secure ? 443 : 80) == target.port ? "" : ":\(target.port)"))
        headers.add(name: "Connection", value: "close")
        if let body = request.body { headers.add(name: "Content-Length", value: String(body.count)) }
        if !headers.contains(name: "accept-encoding") { headers.add(name: "Accept-Encoding", value: "gzip, deflate") }
        let uri: String
        if case .httpProxy = route, !target.secure { uri = target.url.absoluteString }
        else { uri = target.path }
        return HTTPRequestHead(version: .http1_1, method: HTTPMethod(rawValue: request.method.uppercased()), uri: uri, headers: headers)
    }
}
