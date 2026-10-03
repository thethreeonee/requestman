import Foundation
import NIOCore
import NIOHTTP1
import RequestmanCore

extension ProxyConnection {
    func enqueue(_ part: HTTPServerRequestPart) {
        guard pending.count < 128 else { return fail("连接预读缓冲已满", status: 503) }
        pending.append(part)
    }
    func begin(_ input: HTTPRequestHead) {
        guard let client else { return }
        timer?.cancel(); timer = nil
        // Bound tunnel establishment, but do not put a deadline on an HTTP transaction.
        if input.method == .CONNECT {
            timer = client.eventLoop.scheduleTask(in: .seconds(30)) { [self] in fail("CONNECT 建立超时", status: 504) }
        }
        clientKeepsAlive = !isHTTP2 && input.isKeepAlive
        var head = input
        if let metadata = http2RequestMetadata {
            head.headers = HTTPHeaders(metadata.headers.map { ($0.name, $0.value) })
            if !head.headers.contains(name: "host"), let authority = metadata.authority { head.headers.add(name: "host", value: authority) }
        }
        if let authority = tlsAuthority ?? plainAuthority {
            let scheme = tlsAuthority == nil ? "http" : "https"
            let defaultPort = tlsAuthority == nil ? 80 : 443
            let expected = URLComponents(string: scheme + "://" + authority)
            let h2Target = http2RequestMetadata?.authority.flatMap { URLComponents(string: "https://" + $0) }
            let validH2Target = !isHTTP2 || (http2RequestMetadata?.scheme == "https" && h2Target?.host?.lowercased() == expected?.host?.lowercased()
                && (h2Target?.port ?? 443) == (expected?.port ?? 443) && h2Target?.user == nil
                && h2Target?.path.isEmpty == true && h2Target?.query == nil && h2Target?.fragment == nil)
            let hostHeader = head.headers["host"]
            let supplied = hostHeader.count == 1 ? URLComponents(string: scheme + "://" + hostHeader[0]) : nil
            let originAuthority = (expected?.percentEncodedHost ?? "")
                + (expected?.port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? "")
            let fullURL = head.uri.hasPrefix("/") ? scheme + "://" + originAuthority + head.uri : head.uri
            let target = URLComponents(string: fullURL)
            guard validH2Target, head.method != .CONNECT, target?.scheme == scheme,
                  target?.host?.lowercased() == expected?.host?.lowercased(),
                  (target?.port ?? defaultPort) == (expected?.port ?? defaultPort),
                  supplied?.host?.lowercased() == expected?.host?.lowercased(),
                  (supplied?.port ?? defaultPort) == (expected?.port ?? defaultPort),
                  supplied?.user == nil, supplied?.path.isEmpty == true,
                  supplied?.query == nil, supplied?.fragment == nil else {
                record = CaptureRecord(method: head.method.rawValue, url: fullURL)
                return fail("HTTPS 请求与 CONNECT 目标不一致", status: 400)
            }
            head.uri = fullURL
        }
        if head.uri.hasPrefix("ws://") { head.uri = "http://" + head.uri.dropFirst(5) }
        if head.uri.hasPrefix("wss://") { head.uri = "https://" + head.uri.dropFirst(6) }
        originalMethod = head.method.rawValue
        replaySession = shared.replaySession(for: client)
        replaySession?.attach(client, downstream: true)
        record = CaptureRecord(id: replaySession?.request.id ?? UUID(), method: originalMethod, url: head.uri)
        record?.replayID = replaySession?.request.id
        record?.replaySourceID = replaySession?.request.sourceRecordID
        record?.clientHTTPVersion = isHTTP2 ? "HTTP/2" : "HTTP/1.1"
        record?.requestHeaders = fields(head.headers)
        record?.environment = shared.document.withLock { $0.environment?.name ?? "无环境" }
        started = .now
        recordGeneration = replaySession?.generation ?? records.generation
        record?.connectionState = .connecting
        if replaySession?.isCancelled == true { finish(); return }
        if replaySession != nil { startRecordUpdates() }
        if head.method == .CONNECT {
            if let previous = upstream {
                upstream = nil; upstreamTarget = nil
                closeProxyChannel(previous)
            }
            record?.requestBody = .unavailable("加密隧道不采集 HTTP 内容")
            record?.sentBody = .unavailable("加密隧道不采集 HTTP 内容")
            record?.receivedBody = .unavailable("加密隧道不采集 HTTP 内容")
            record?.responseBody = .unavailable("加密隧道不采集 HTTP 内容")
            pendingTunnelHead = head
            return
        }
        requestBodyCollector = CaptureBodyCollector(headers: fields(head.headers))
        record?.sentBody = .unavailable("请求未发送至上游")
        record?.receivedBody = .unavailable("尚未收到上游响应")
        webSocketRequest = head.headers["upgrade"].contains { $0.lowercased() == "websocket" }
        guard head.method != .TRACE, head.headers["upgrade"].isEmpty || webSocketRequest else { return fail("不支持此协议升级或 TRACE", status: 501) }
        if webSocketRequest {
            guard head.method == .GET, headerTokens(head.headers, name: "connection").contains("upgrade"),
                  head.headers["sec-websocket-version"] == ["13"], head.headers["sec-websocket-key"].count == 1,
                  Data(base64Encoded: head.headers["sec-websocket-key"][0])?.count == 16,
                  head.headers["transfer-encoding"].isEmpty,
                  head.headers["content-length"].allSatisfy({ $0 == "0" }) else { return fail("WebSocket 握手无效", status: 400) }
            record?.captureProtocol = .webSocket
        }
        guard let url = URL(string: head.uri), ["http", "https"].contains(url.scheme ?? ""), url.host != nil,
              url.user == nil, url.fragment == nil else { return fail("需要 HTTP 或 HTTPS 绝对请求地址", status: 400) }
        do {
            let document = shared.document.withLock { $0 }
            var draft = HTTPMessageDraft(method: originalMethod, url: head.uri, headers: fields(head.headers))
            if let record {
                let httpClient = ScriptHTTPService(configuration: configuration, shared: shared,
                    records: records, eventLoop: client.eventLoop)
                transaction = TransactionCoordinator(document: document, request: draft, id: record.id,
                    date: record.startedAt, httpClient: httpClient)
            }
            record?.environment = document.environment?.name ?? "无环境"
            if let match {
                traceRecorder = TransactionTraceRecorder(records: records, generation: recordGeneration, workflowName: match.workflow.name)
                self.record?.project = match.project; self.record?.workflow = match.workflow.name
                self.record?.matchedWorkflowID = match.workflow.id
                shared.events.append(.init(.matched, transactionID: record?.id, workflowID: match.workflow.id))
                shared.ruleHitNotifications.append(workflowID: match.workflow.id, name: match.workflow.name)
                if transaction?.requirements(for: .request).needsCompleteBody == true {
                    if transaction?.requirements(for: .request).hasScripts == true {
                        guard reserveScriptFlow() else { return }
                    }
                    scriptRequestHead = head; scriptRequestDraft = draft
                    if head.headers["expect"].contains(where: { $0.lowercased() == "100-continue" }) {
                        client.writeAndFlush(HTTPServerResponsePart.head(HTTPResponseHead(version: messageVersion, status: .continue)), promise: nil)
                        scriptRequestHead?.headers.remove(name: "Expect")
                    }
                    return
                }
                if transaction?.requirements(for: .request).requiresBackground == true {
                    executeScriptFlow(response: false, draft: draft) { [self, head] result in
                        do { try continueRequest(head, draft: result) }
                        catch { fail(error.localizedDescription, status: 400) }
                    }
                    return
                }
                try applyRecordedSteps(response: false, to: &draft)
            }
            try continueRequest(head, draft: draft)
        } catch { fail(error.localizedDescription, status: 400) }
    }
    func continueRequest(_ head: HTTPRequestHead, draft: HTTPMessageDraft) throws {
        guard let client, isProcessing else { return }
            record?.finalURL = draft.url; record?.sentMethod = draft.method
            request = draft
            startRecordUpdates()
            if webSocketRequest && (draft.method != "GET" || draft.hasReplacementBody) && requestDisposition != .localResponse {
                throw WorkflowError.invalid("WebSocket 握手必须使用 GET 且不含 Body")
            }
            if requestDisposition == .localResponse {
                record?.outcome = .mocked
                record?.sentBody = .unavailable("本地响应，请求未发送至上游")
                record?.receivedBody = .unavailable("本地响应，没有上游响应")
                var reply = draft
                if transaction?.requirements(for: .response).requiresBackground == true {
                    executeScriptFlow(response: true, draft: reply) { [self] in sendStatic($0) }
                    return
                }
                if transaction != nil { try applyRecordedSteps(response: true, to: &reply) }
                return sendStatic(reply)
            }
            guard let target = URLComponents(string: draft.url), let host = target.host else { throw WorkflowError.invalid("目标地址无效") }
            let secure = target.scheme == "https"
            let port = target.port ?? (secure ? 443 : 80)
            guard !isLoop(host, port: port) else { throw WorkflowError.invalid("请求目标会形成代理循环") }
            var headers = cleanHeaders(draft.headers)
            headers.replaceOrAdd(name: "Host", value: target.percentEncodedHost.map { $0 + (target.port.map { ":\($0)" } ?? "") } ?? host)
            if !isHTTP2 { headers.replaceOrAdd(name: "Connection", value: clientKeepsAlive ? "keep-alive" : "close") }
            if webSocketRequest {
                headers.replaceOrAdd(name: "Connection", value: "Upgrade")
                headers.replaceOrAdd(name: "Upgrade", value: "websocket")
                headers.replaceOrAdd(name: "Sec-WebSocket-Key", value: head.headers["sec-websocket-key"][0])
                headers.replaceOrAdd(name: "Sec-WebSocket-Version", value: "13")
                // Base support deliberately negotiates no extensions. Never advertise compression we cannot inspect.
                headers.remove(name: "Sec-WebSocket-Extensions")
            }
            headers.remove(name: "Expect")
            if let body = draft.replacementBytes {
                headers.remove(name: "Transfer-Encoding"); headers.replaceOrAdd(name: "Content-Length", value: String(body.count))
            } else if !isHTTP2 && head.headers.contains(name: "transfer-encoding") {
                headers.remove(name: "Content-Length"); headers.replaceOrAdd(name: "Transfer-Encoding", value: "chunked")
            }
            let uri: String
            let endpoint: ProxyEndpoint
            if case .httpProxy(let proxy) = configuration.upstream { endpoint = proxy }
            else { endpoint = ProxyEndpoint(host: host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), port: port) }
            if case .httpProxy = configuration.upstream, !secure { uri = draft.url }
            else { uri = (target.percentEncodedPath.isEmpty ? "/" : target.percentEncodedPath) + (target.percentEncodedQuery.map { "?\($0)" } ?? "") }
            record?.sentHeaders = fields(headers)
            record?.hasSentRequestHeaders = true
            let forwarded = HTTPRequestHead(version: messageVersion, method: HTTPMethod(rawValue: draft.method), uri: uri, headers: headers)
            if head.headers["expect"].contains(where: { $0.lowercased() == "100-continue" }) {
                client.writeAndFlush(HTTPServerResponsePart.head(HTTPResponseHead(version: messageVersion, status: .continue)), promise: nil)
            }
            connectHTTP(endpoint: endpoint, targetHost: host, targetPort: port, secure: secure, on: client.eventLoop).whenComplete { [self] result in
                switch result {
                case .failure(let error): fail(error.localizedDescription, status: 502)
                case .success(let channel):
                    guard isProcessing else { closeProxyChannel(channel); return }
                    guard !isLoopChannel(channel) else { closeProxyChannel(channel); fail("目标解析后指向代理自身", status: 502); return }
                    upstream = channel; connected = true
                    record?.upstreamHTTPVersion = isHTTP2 ? "HTTP/2" : "HTTP/1.1"
                    sentBodyCollector = CaptureBodyCollector(headers: record?.sentHeaders ?? [])
                    trackRequestWrite(channel.write(HTTPClientRequestPart.head(forwarded)))
                    if let body = request?.replacementBytes {
                        sentBodyCollector?.append(body)
                        trackRequestWrite(channel.write(HTTPClientRequestPart.body(.byteBuffer(channel.allocator.buffer(bytes: body)))))
                    }
                    for part in pending { forward(part) }
                    pending.removeAll()
                    flushRequest()
                    channel.read()
                }
            }
    }
    func forward(_ part: HTTPServerRequestPart) {
        guard let upstream, !tunnel else { return }
        switch part {
        case .body(let bytes):
            if request?.hasReplacementBody != true {
                sentBodyCollector?.append(bytes.readableBytesView)
                trackRequestWrite(upstream.write(HTTPClientRequestPart.body(.byteBuffer(bytes))))
            }
        case .end:
            let trailers = isHTTP2 && request?.hasReplacementBody != true ? requestTrailers : nil
            record?.sentTrailers = trailers.map(fields)
            let written = upstream.write(HTTPClientRequestPart.end(trailers))
            trackRequestWrite(written)
            written.whenSuccess { [self] in requestWriteComplete = !requestWriteFailed }
        case .head: break
        }
    }
    func trackRequestWrite(_ future: EventLoopFuture<Void>) {
        lastRequestWrite = future
        future.whenFailure { [self] error in
            requestWriteFailed = true
            requestWriteComplete = false
            fail(error.localizedDescription, status: 502)
        }
    }
    func trackResponseWrite(_ future: EventLoopFuture<Void>) {
        lastResponseWrite = future
        future.whenFailure { [self] error in
            responseWriteFailed = true
            responseWriteComplete = false
            fail(error.localizedDescription, status: 502)
        }
    }
    func flushRequest() {
        guard let upstream else { return }
        upstream.flush()
        let flushed = lastRequestWrite ?? upstream.eventLoop.makeSucceededFuture(())
        flushed.whenComplete { [self] result in
            if case .failure(let error) = result { fail(error.localizedDescription, status: 502) }
            else if !requestEnded && isProcessing { client?.read() }
        }
    }
}
