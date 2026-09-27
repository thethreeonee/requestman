import Foundation
import NIOCore
import NIOWebSocket
import RequestmanCore

/// Both relays and the session are confined to the proxy's single NIO event loop.
final class WebSocketSession: @unchecked Sendable {
    private var client: Channel?
    private var server: Channel?
    private var record: CaptureRecord
    private let records: CaptureRecordBuffer
    private let generation: UInt64
    private let shared: ProxySharedState
    private var store: CaptureStreamStore? = CaptureStreamStore()
    private let started = ContinuousClock.now
    private var timer: Scheduled<Void>?
    private var closeTimer: Scheduled<Void>?
    private var closedDirections: Set<CaptureStreamMessage.Direction> = []
    private var finished = false
    private var failureReason: String?
    var acceptsFrames: Bool { !finished && failureReason == nil }
    init(client: Channel, server: Channel, record: CaptureRecord, records: CaptureRecordBuffer, generation: UInt64, shared: ProxySharedState) {
        self.client = client; self.server = server; self.record = record; self.records = records
        self.generation = generation; self.shared = shared
        self.record.captureProtocol = .webSocket; self.record.connectionState = .open
        self.record.stream = store; self.record.receivedStream = store
        self.record.requestBody = .unavailable("WebSocket 握手没有请求 Body")
        self.record.sentBody = .unavailable("WebSocket 握手没有请求 Body")
        self.record.receivedBody = .unavailable("WebSocket 数据保存在消息列表中")
        self.record.responseBody = .unavailable("WebSocket 数据保存在消息列表中")
    }
    func start() { publish(); scheduleUpdate() }
    private func scheduleUpdate() {
        timer = client?.eventLoop.scheduleTask(in: .milliseconds(200)) { [weak self] in
            guard let self, !finished else { return }
            publish(); scheduleUpdate()
        }
    }
    private func publish() {
        discardClearedCapture()
        let elapsed = started.duration(to: .now).components
        record.duration = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        record.revision &+= 1
        records.append(record, generation: generation)
    }
    func count(_ bytes: Int, direction: CaptureStreamMessage.Direction) {
        if direction == .sent { record.requestBytes += bytes } else { record.responseBytes += bytes }
    }
    func append(_ message: CaptureStreamMessage, on loop: EventLoop) -> EventLoopFuture<Void> {
        discardClearedCapture()
        guard let store else { return loop.makeSucceededVoidFuture() }
        let promise = loop.makePromise(of: Void.self)
        store.append(message) { promise.succeed(()) }
        return promise.futureResult
    }
    private func discardClearedCapture() {
        if !records.isCurrent(generation) { store = nil; record.stream = nil; record.receivedStream = nil }
    }
    func receivedClose(direction: CaptureStreamMessage.Direction, payload: Data) {
        closedDirections.insert(direction)
        if payload.count >= 2 {
            let code = UInt16(payload[payload.startIndex]) << 8 | UInt16(payload[payload.startIndex + 1])
            record.closeReason = "\(code) " + String(decoding: payload.dropFirst(2), as: UTF8.self)
        } else { record.closeReason = "关闭握手（无状态码）" }
        if closeTimer == nil {
            closeTimer = client?.eventLoop.scheduleTask(in: .seconds(5)) { [weak self] in self?.finish(error: "WebSocket 关闭握手超时") }
        }
    }
    var closeHandshakeComplete: Bool { closedDirections.count == 2 }
    func peerClosed() {
        if shared.isStopping { record.closeReason = "捕获已停止"; finish() }
        else { finish(error: closeHandshakeComplete ? nil : "WebSocket 连接中断（1006），关闭握手未完成") }
    }
    func fail(_ description: String, closeCode: UInt16 = 1002) {
        guard acceptsFrames else { return }
        if shared.isStopping { finish(); return }
        failureReason = description
        record.closeReason = "\(closeCode) \(description)"
        // Protocol failure closes both hops, with server/client masking roles preserved.
        if let client, let server {
            var bytes = client.allocator.buffer(capacity: 2); bytes.writeInteger(closeCode)
            let sent = client.writeAndFlush(WebSocketFrame(fin: true, opcode: .connectionClose, data: bytes))
            let upstream = server.writeAndFlush(WebSocketFrame(fin: true, opcode: .connectionClose, maskKey: .random(), data: bytes))
            sent.and(upstream).whenComplete { [self] _ in finish(error: description) }
        } else { finish(error: description) }
    }
    func finish(error: String? = nil) {
        guard !finished else { return }; finished = true
        let error = shared.isStopping ? nil : failureReason ?? error
        if shared.isStopping { record.closeReason = "捕获已停止" }
        timer?.cancel(); closeTimer?.cancel(); timer = nil; closeTimer = nil
        record.error = error; record.connectionState = error == nil ? .closed : .failed
        if error != nil { record.outcome = .failed }
        let elapsed = started.duration(to: .now).components
        record.duration = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18; record.revision &+= 1
        shared.events.append(.init(shared.isStopping ? .cancelled : (error == nil ? .completed : .failed),
            transactionID: record.id, workflowID: record.matchedWorkflowID, message: error))
        let snapshot = record, records = records, generation = generation
        if let store { store.flush { records.append(snapshot, generation: generation) } }
        else { records.append(snapshot, generation: generation) }
        let downstream = client, upstream = server
        client = nil; server = nil
        if let downstream { closeProxyChannel(downstream) }
        if let upstream { closeProxyChannel(upstream) }
    }
}

final class WebSocketRelay: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    private let peer: Channel
    private let direction: CaptureStreamMessage.Direction
    private let session: WebSocketSession
    private var fragmentOpcode: WebSocketOpcode?
    private var fragments = Data()
    private var lastWrite: EventLoopFuture<Void>?
    private var lastCapture: EventLoopFuture<Void>?
    private var closing = false
    init(peer: Channel, direction: CaptureStreamMessage.Direction, session: WebSocketSession) {
        self.peer = peer; self.direction = direction; self.session = session
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard session.acceptsFrames else { return }
        let frame = unwrapInboundIn(data)
        guard (direction == .sent) == (frame.maskKey != nil), !frame.rsv1, !frame.rsv2, !frame.rsv3 else {
            session.fail("WebSocket 帧掩码或保留位无效"); return
        }
        let bytes = frame.unmaskedData
        let payload = Data(bytes.readableBytesView)
        do {
            switch frame.opcode {
            case .text, .binary:
                guard fragmentOpcode == nil, !closing else { throw WorkflowError.invalid("WebSocket 消息分片顺序无效") }
                if frame.fin { try capture(payload, opcode: frame.opcode, on: context.eventLoop) }
                else { fragmentOpcode = frame.opcode; fragments = payload }
            case .continuation:
                guard let opcode = fragmentOpcode, !closing else { throw WorkflowError.invalid("WebSocket 缺少起始消息帧") }
                fragments.append(payload)
                if frame.fin { try capture(fragments, opcode: opcode, on: context.eventLoop); fragments = Data(); fragmentOpcode = nil }
            case .ping, .pong:
                lastCapture = session.append(.init(direction: direction, kind: frame.opcode == .ping ? "Ping" : "Pong", data: payload), on: context.eventLoop)
            case .connectionClose:
                guard payload.count != 1 else { throw WorkflowError.invalid("WebSocket 关闭帧无效") }
                if payload.count >= 2 {
                    let code = UInt16(payload[payload.startIndex]) << 8 | UInt16(payload[payload.startIndex + 1])
                    guard (1000...1014).contains(code) && ![1004, 1005, 1006].contains(code) || (3000...4999).contains(code) else { throw WorkflowError.invalid("WebSocket 关闭状态码无效") }
                    guard String(data: payload.dropFirst(2), encoding: .utf8) != nil else { throw WebSocketPayloadError.invalidUTF8 }
                }
                closing = true
                lastCapture = session.append(.init(direction: direction, kind: "Close", data: payload), on: context.eventLoop)
                session.receivedClose(direction: direction, payload: payload)
            default: throw WorkflowError.invalid("不支持的 WebSocket opcode")
            }
            session.count(payload.count, direction: direction)
            let forwarded = WebSocketFrame(fin: frame.fin, opcode: frame.opcode, maskKey: direction == .sent ? .random() : nil, data: bytes)
            lastWrite = peer.writeAndFlush(forwarded)
        } catch WebSocketPayloadError.invalidUTF8 { session.fail("WebSocket 内容不是有效的 UTF-8", closeCode: 1007) }
        catch { session.fail(error.localizedDescription) }
    }
    private func capture(_ data: Data, opcode: WebSocketOpcode, on loop: EventLoop) throws {
        if opcode == .text, String(data: data, encoding: .utf8) == nil { throw WebSocketPayloadError.invalidUTF8 }
        lastCapture = session.append(.init(direction: direction, kind: opcode == .text ? "文本" : "二进制", data: data), on: loop)
    }
    func channelReadComplete(context: ChannelHandlerContext) {
        let channel = context.channel
        let written = lastWrite ?? context.eventLoop.makeSucceededVoidFuture()
        written.and(lastCapture ?? context.eventLoop.makeSucceededVoidFuture()).whenComplete { [self] result in
            switch result {
            case .failure(let error): session.finish(error: error.localizedDescription)
            case .success:
                if session.closeHandshakeComplete { session.finish() }
                else { channel.read() }
            }
        }
    }
    func channelInactive(context: ChannelHandlerContext) {
        if !fragments.isEmpty {
            _ = session.append(.init(direction: direction, kind: "未完成消息", data: fragments), on: context.eventLoop)
            fragments = Data()
        }
        session.peerClosed()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { session.fail(error.localizedDescription) }
}

private enum WebSocketPayloadError: Error { case invalidUTF8 }

/// CONNECT can carry plaintext ws:// as well as TLS. Inspect only the protocol prefix and replay it once.
final class ConnectProtocolDetector: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    enum Kind: Sendable { case http, tls, opaque }
    private var buffered = ByteBuffer()
    private var configuring = false
    private let configure: @Sendable (Kind) -> EventLoopFuture<Void>
    private let onClose: @Sendable () -> Void
    init(configure: @escaping @Sendable (Kind) -> EventLoopFuture<Void>, onClose: @escaping @Sendable () -> Void) {
        self.configure = configure; self.onClose = onClose
    }
    func channelInactive(context: ChannelHandlerContext) { onClose() }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bytes = unwrapInboundIn(data); buffered.writeBuffer(&bytes)
        guard !configuring, let first: UInt8 = buffered.getInteger(at: buffered.readerIndex) else { return }
        let kind: Kind
        if first == 22 { kind = .tls }
        else if first == 71 {
            guard buffered.readableBytes >= 4 else { return }
            kind = buffered.getString(at: buffered.readerIndex, length: 4) == "GET " ? .http : .opaque
        } else { kind = .opaque }
        configuring = true
        let channel = context.channel
        // Decoder removal can deliver CONNECT leftovers synchronously. Replay after that removal has unwound.
        channel.eventLoop.execute { [self] in
            configure(kind).flatMap { [self] in channel.pipeline.removeHandler(self) }.whenComplete { [self] result in
                switch result {
                case .failure: closeProxyChannel(channel)
                case .success:
                    channel.pipeline.fireChannelRead(buffered); buffered = ByteBuffer()
                    channel.pipeline.fireChannelReadComplete()
                }
            }
        }
    }
    func channelReadComplete(context: ChannelHandlerContext) { if !configuring { context.read() } }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
