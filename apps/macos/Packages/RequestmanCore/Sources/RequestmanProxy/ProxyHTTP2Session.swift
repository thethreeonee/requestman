import Foundation
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOPosix
import NIOTLS
import RequestmanCore

/// One downstream TLS connection. All state and origins stay on its event loop.
/// Transactions own stream channels, never the shared TCP/TLS channels.
final class ProxyHTTP2Session: @unchecked Sendable {
    let downstream: Channel
    let configuration: ExplicitProxyConfiguration
    let shared: ProxySharedState
    private var origins: [String: ProxyHTTP2Origin] = [:]
    private var closed = false
    private var activeStreams = 0
    private var idleTimer: Scheduled<Void>?

    init(downstream: Channel, configuration: ExplicitProxyConfiguration, shared: ProxySharedState) {
        self.downstream = downstream; self.configuration = configuration; self.shared = shared
        downstream.closeFuture.whenComplete { [self] _ in
            closed = true; idleTimer?.cancel(); idleTimer = nil
            for origin in origins.values { origin.close() }
            origins.removeAll()
        }
        scheduleIdleClose()
    }

    func accept(_ stream: Channel) {
        activeStreams += 1; idleTimer?.cancel(); idleTimer = nil
        stream.closeFuture.whenComplete { [self] _ in
            activeStreams -= 1
            if activeStreams == 0 && !closed { scheduleIdleClose() }
        }
    }
    private func scheduleIdleClose() {
        idleTimer = downstream.eventLoop.scheduleTask(in: .seconds(30)) { [self] in closeProxyChannel(downstream) }
    }

    func stream(host: String, port: Int, endpoint: ProxyEndpoint, owner: ProxyConnection) -> EventLoopFuture<Channel> {
        let loop = downstream.eventLoop
        guard !closed else { return loop.makeFailedFuture(WorkflowError.invalid("客户端连接已关闭")) }
        let key = "\(host.lowercased()):\(port)-\(endpoint.host):\(endpoint.port)"
        let origin: ProxyHTTP2Origin
        if let existing = origins[key], !existing.draining {
            origin = existing
        } else {
            origin = ProxyHTTP2Origin(loop: loop, shared: shared)
            origins[key] = origin
            origin.onRetire = { [weak self, weak origin] in
                guard let self, self.origins[key] === origin else { return }
                self.origins.removeValue(forKey: key)
            }
            origin.connect(host: host, port: port, endpoint: endpoint, configuration: configuration)
        }
        return origin.stream(owner: owner)
    }
}

private final class ProxyHTTP2Origin: @unchecked Sendable {
    let loop: EventLoop
    let shared: ProxySharedState
    let ready: EventLoopPromise<NIOHTTP2Handler.StreamMultiplexer>
    var channel: Channel?
    var draining = false
    var onRetire: (@Sendable () -> Void)?
    private var stopped = false
    private var active = 0
    private var idleTimer: Scheduled<Void>?

    init(loop: EventLoop, shared: ProxySharedState) {
        self.loop = loop; self.shared = shared; ready = loop.makePromise()
    }

    func connect(host: String, port: Int, endpoint: ProxyEndpoint, configuration: ExplicitProxyConfiguration) {
        let connection = ClientBootstrap(group: loop).connectTimeout(.seconds(5))
            .channelInitializer { [shared] channel in
                guard shared.register(channel, downstream: false) else { return channel.close() }
                return channel.eventLoop.makeSucceededVoidFuture()
            }.connect(host: endpoint.host, port: endpoint.port)
        connection.flatMap { [self] channel -> EventLoopFuture<NIOHTTP2Handler.StreamMultiplexer> in
            self.channel = channel
            guard !stopped, !shared.isStopping,
                  !(channel.remoteAddress?.port == configuration.port && LocalNetwork.isLocalHost(channel.remoteAddress?.ipAddress ?? "")) else {
                closeProxyChannel(channel)
                return loop.makeFailedFuture(WorkflowError.invalid("连接已取消或指向代理自身"))
            }
            let tunnel: EventLoopFuture<Void>
            if case .httpProxy = configuration.upstream {
                let handshake = loop.makePromise(of: Void.self)
                let authority = host + ":" + String(port)
                tunnel = channel.pipeline.addHTTPClientHandlers(leftOverBytesStrategy: .forwardBytes, decoderLimitConfiguration: proxyDecoderLimits()).flatMap {
                    channel.pipeline.addHandler(TunnelHandshake(ready: handshake))
                }.flatMap {
                    channel.write(HTTPClientRequestPart.head(HTTPRequestHead(version: .http1_1, method: .CONNECT, uri: authority, headers: HTTPHeaders([("Host", authority)]))), promise: nil)
                    channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
                    return handshake.futureResult
                }
            } else { tunnel = loop.makeSucceededVoidFuture() }
            let deadline = loop.scheduleTask(in: .seconds(30)) { closeProxyChannel(channel) }
            let result = tunnel.flatMap {
                ProxyTLS.negotiateClient(channel: channel, host: host, http2: true, shared: self.shared) {
                    channel.configureHTTP2Pipeline(mode: .client, connectionConfiguration: proxyHTTP2Configuration(server: false), streamConfiguration: .init(), inboundStreamInitializer: { stream in stream.close() })
                        .flatMap { multiplexer in
                            channel.pipeline.addHandler(HTTP2OriginLifecycle(origin: self)).map { multiplexer }
                        }
                }
            }
            result.whenComplete { _ in deadline.cancel() }
            return result
        }.whenComplete { [self] result in
            switch result {
            case .success(let multiplexer):
                ready.succeed(multiplexer)
                if stopped { close() }
            case .failure(let error):
                draining = true; onRetire?(); onRetire = nil
                ready.fail(error)
                if let channel { closeProxyChannel(channel) }
            }
        }
    }

    func stream(owner: ProxyConnection) -> EventLoopFuture<Channel> {
        // Includes streams waiting for TLS/SETTINGS, so a stalled origin cannot create an unbounded queue.
        guard !draining, active < 100 else { return loop.makeFailedFuture(WorkflowError.invalid("HTTP/2 上游连接不可用或并发流已满")) }
        idleTimer?.cancel(); active += 1
        let result: EventLoopFuture<Channel> = ready.futureResult.flatMap { [self] multiplexer in
            guard !draining, !stopped, owner.isProcessing else { return loop.makeFailedFuture(WorkflowError.invalid("HTTP/2 请求已取消或连接正在退出")) }
            return multiplexer.createStreamChannel { stream in
                stream.setOption(ChannelOptions.autoRead, value: false).flatMap {
                    stream.eventLoop.makeCompletedFuture {
                        try stream.pipeline.syncOperations.addHandlers(ProxyHTTP2Headers(owner: owner, response: true), HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https), ProxyResponseHandler(owner: owner))
                    }
                }
            }
        }
        result.whenComplete { [self] result in
            switch result {
            case .success(let stream): stream.closeFuture.whenComplete { [self] _ in release() }
            case .failure: release()
            }
        }
        return result
    }

    private func release() {
        active -= 1
        if active == 0 {
            if draining { close() }
            else { idleTimer = loop.scheduleTask(in: .seconds(30)) { [self] in close() } }
        }
    }
    func goAway() { draining = true; onRetire?(); onRetire = nil; if active == 0 { close() } }
    func close() {
        stopped = true; draining = true; idleTimer?.cancel(); idleTimer = nil
        onRetire?(); onRetire = nil
        if let channel, channel.isActive { closeProxyChannel(channel) }
    }
}

private final class HTTP2OriginLifecycle: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTP2Frame
    let origin: ProxyHTTP2Origin
    init(origin: ProxyHTTP2Origin) { self.origin = origin }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .goAway = unwrapInboundIn(data).payload { origin.goAway() }
        context.fireChannelRead(data)
    }
    func channelInactive(context: ChannelHandlerContext) { origin.close(); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Stream errors belong to their child channel; only connection errors tear down TCP.
        if !(error is NIOHTTP2Errors.StreamError) { origin.close() }
        context.fireErrorCaught(error)
    }
}

extension ProxyTLS {
    /// Do not write an HTTP request until TLS has confirmed the required protocol.
    static func negotiateClient<Value: Sendable>(channel: Channel, host: String, http2: Bool, shared: ProxySharedState,
                                                 configure: @escaping @Sendable () -> EventLoopFuture<Value>) -> EventLoopFuture<Value> {
        let state = TLSNegotiationState<Value>(channel: channel)
        do {
            try channel.pipeline.syncOperations.addHandler(client(host: host, testTrustRoots: shared.upstreamTrustRoots, http2: http2))
            try channel.pipeline.syncOperations.addHandler(ApplicationProtocolNegotiationHandler { result in
                let expected = http2 ? "h2" : "http/1.1"
                // No ALPN remains valid for legacy HTTP/1.1 servers; HTTP/2 always requires h2.
                guard result == .negotiated(expected) || (!http2 && result == .fallback) else {
                    let error = WorkflowError.invalid("协议不匹配：客户端要求 \(expected)，上游未协商相同协议")
                    state.complete(.failure(error)); channel.close(promise: nil)
                    return channel.eventLoop.makeFailedFuture(error)
                }
                return configure().map { value in state.complete(.success(value)) }
            })
            try channel.pipeline.syncOperations.addHandler(TLSNegotiationFailure(state: state))
            state.startDeadline()
            channel.read()
        } catch { state.complete(.failure(error)) }
        return state.promise.futureResult
    }
}

private final class TLSNegotiationState<Value: Sendable>: @unchecked Sendable {
    let channel: Channel
    let promise: EventLoopPromise<Value>
    var completed = false
    var timer: Scheduled<Void>?
    init(channel: Channel) { self.channel = channel; promise = channel.eventLoop.makePromise() }
    func startDeadline() {
        guard !completed else { return }
        timer = channel.eventLoop.scheduleTask(in: .seconds(30)) { [self] in
            complete(.failure(WorkflowError.invalid("上游 TLS 协议协商超时"))); channel.close(promise: nil)
        }
    }
    func complete(_ result: Result<Value, Error>) {
        guard !completed else { return }; completed = true; timer?.cancel(); timer = nil
        promise.completeWith(result)
    }
}
private final class TLSNegotiationFailure<Value: Sendable>: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let state: TLSNegotiationState<Value>
    init(state: TLSNegotiationState<Value>) { self.state = state }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { context.fireChannelRead(data) }
    func channelReadComplete(context: ChannelHandlerContext) {
        if !state.completed { context.read() }
        context.fireChannelReadComplete()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        state.complete(.failure(WorkflowError.invalid("上游 TLS / 协议协商失败：" + ProxyTLS.errorDescription(error))))
        context.fireErrorCaught(error)
    }
    func channelInactive(context: ChannelHandlerContext) {
        state.complete(.failure(WorkflowError.invalid("上游在协议协商完成前关闭连接")))
        context.fireChannelInactive()
    }
}

func proxyHTTP2Configuration(server: Bool) -> NIOHTTP2Handler.ConnectionConfiguration {
    var configuration = NIOHTTP2Handler.ConnectionConfiguration()
    configuration.initialSettings = [HTTP2Setting(parameter: .maxConcurrentStreams, value: 100),
                                     HTTP2Setting(parameter: .maxHeaderListSize, value: Int(UInt32.max))]
    configuration.maximumSequentialContinuationFrames = .max
    if !server { configuration.initialSettings.append(HTTP2Setting(parameter: .enablePush, value: 0)) }
    return configuration
}
