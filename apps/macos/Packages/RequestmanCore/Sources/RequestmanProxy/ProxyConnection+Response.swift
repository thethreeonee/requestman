import Foundation
import NIOCore
import NIOHTTP1
import RequestmanCore

extension ProxyConnection {
    func writeResponseEnd(_ trailers: HTTPHeaders?) -> EventLoopFuture<Void> {
        let client = client!
        responseEndWritePending = true
        let future = client.writeAndFlush(HTTPServerResponsePart.end(trailers))
        future.whenComplete { [self] _ in responseEndWritePending = false }
        return future
    }

    func receive(_ part: HTTPClientResponsePart, channel: Channel) {
        guard isProcessing, record != nil, channel === upstream else { return }
        do {
            switch part {
            case .head(var head):
                if let headers = http2ResponseHeaders { head.headers = HTTPHeaders(headers.map { ($0.name, $0.value) }) }
                if head.status.code < 200 {
                    informationalResponse = true
                    if isHTTP2, head.status != .switchingProtocols, let client {
                        trackResponseWrite(client.write(HTTPServerResponsePart.head(HTTPResponseHead(version: .http2, status: head.status, headers: cleanHeaders(fields(head.headers))))))
                    }
                    if head.status == .switchingProtocols { pendingWebSocketResponse = head; webSocketUpgrading = true }
                    return
                }
                informationalResponse = false
                originKeepsAlive = head.isKeepAlive
                guard !responseStarted else { return fail("重复响应头", status: 502) }
                var draft = HTTPMessageDraft(method: originalMethod, url: request?.url ?? "", status: Int(head.status.code), headers: fields(head.headers))
                record?.receivedHeaders = draft.headers
                record?.originalStatus = draft.status
                receivedBodyCollector = CaptureBodyCollector(headers: draft.headers)
                // Only the original upstream response selects stream execution.
                // Request hints, the legacy UI flag and later Header edits do not convert HTTP into SSE.
                if isSSE(draft.headers) {
                    try receiveSSEHead(draft)
                    return
                }
                if (transaction?.requirements(for: .response).needsCompleteBody == true || transaction?.requirements(for: .response).hasDelay == true) {
                    if transaction?.requirements(for: .response).hasScripts == true {
                        guard reserveScriptFlow() else { return }
                    }
                    scriptResponseDraft = draft
                    return
                }
                if transaction?.requirements(for: .response).hasBodyFile == true {
                    readingResponseBodyFile = true
                    executeScriptFlow(response: true, draft: draft) { [self] result in
                        readingResponseBodyFile = false
                        startStreamingResponse(result)
                        if responseEnded { endStreamingResponse(channel) }
                        else { responseReadComplete(channel) }
                    }
                    return
                }
                if transaction != nil { try applyRecordedSteps(response: true, to: &draft) }
                startStreamingResponse(draft)
            case .body(let buffer):
                record?.responseBytes += buffer.readableBytes
                receivedBodyCollector?.append(buffer.readableBytesView)
                if let stream = record?.receivedStream { appendSSE(buffer, to: stream) }
                if sseWaiting { ssePending.append(buffer); return }
                // File replacement never needs the original body; only capture the current read batch.
                if readingResponseBodyFile { return }
                if scriptResponseDraft != nil {
                    scriptResponseBytes.append(contentsOf: buffer.readableBytesView)
                    return
                }
                if let response, !response.hasReplacementBody, allowsBody(response.status) {
                    responseBodyCollector?.append(buffer.readableBytesView)
                    if let client { trackResponseWrite(client.write(HTTPServerResponsePart.body(.byteBuffer(buffer)))) }
                }
            case .end(let trailers):
                if !informationalResponse { responseTrailers = trailers; record?.receivedTrailers = trailers.map(fields) }
                if let upgrade = pendingWebSocketResponse {
                    pendingWebSocketResponse = nil
                    channel.eventLoop.execute { [self] in
                        guard isProcessing else { return }
                        do { try upgradeWebSocket(upgrade) }
                        catch { fail(error.localizedDescription, status: 502) }
                    }
                    return
                }
                if informationalResponse { informationalResponse = false; return }
                if readingResponseBodyFile || sseWaiting { responseEnded = true; return }
                if var draft = scriptResponseDraft {
                    scriptResponseDraft = nil; responseEnded = true
                    draft.bodyData = scriptResponseBytes
                    executeScriptFlow(response: true, draft: draft) { [self] result in
                        sendBufferedResponse(result)
                    }
                    return
                }
                endStreamingResponse(channel)
            }
        } catch { fail(error.localizedDescription, status: 502) }
    }
    func startStreamingResponse(_ draft: HTTPMessageDraft) {
        response = draft
        record?.connectionState = .open
        responseKeepsAlive = clientKeepsAlive && requestEnded && requestWriteComplete
        let headers = responseHeaders(draft, keepAlive: responseKeepsAlive)
        record?.responseHeaders = fields(headers); record?.status = draft.status
        responseBodyCollector = CaptureBodyCollector(headers: fields(headers))
        if record?.captureProtocol == .sse {
            let stream = record?.receivedStream
            record?.stream = stream
            responseBodyCollector = nil
            record?.responseBody = .unavailable("SSE 内容保存在事件流中")
        }
        responseStarted = true
        if let client {
            trackResponseWrite(client.write(HTTPServerResponsePart.head(HTTPResponseHead(version: messageVersion, status: .init(statusCode: draft.status), headers: headers))))
        }
        if let body = draft.replacementBytes, allowsBody(draft.status), let client {
            responseBodyCollector?.append(body)
            trackResponseWrite(client.write(HTTPServerResponsePart.body(.byteBuffer(client.allocator.buffer(bytes: body)))))
        }
    }
    func endStreamingResponse(_ channel: Channel) {
        guard responseStarted, let client else { return fail("上游未返回完整响应", status: 502) }
        responseEnded = true
        let trailers = isHTTP2 && response?.hasReplacementBody != true ? responseTrailers : nil
        record?.responseTrailers = trailers.map(fields)
        writeResponseEnd(trailers).whenComplete { [self] result in
            if case .success = result, !responseWriteFailed, responseKeepsAlive, failureMessage == nil {
                responseWriteComplete = true
                finish()
                prepareNextRequest()
            } else {
                if case .failure(let error) = result { finish(error: error.localizedDescription) }
                else { responseWriteComplete = !responseWriteFailed; finish() }
                closeProxyChannel(client); closeProxyChannel(channel)
            }
        }
    }
    func responseReadComplete(_ channel: Channel) {
        guard let client, isProcessing, record != nil, channel === upstream else { return }
        client.flush()
        guard !responseEnded, !readingResponseBodyFile, !sseWaiting, !webSocketUpgrading else { return }
        let flushed = lastResponseWrite ?? channel.eventLoop.makeSucceededFuture(())
        let ready = flushed.and(lastStreamWrite ?? channel.eventLoop.makeSucceededVoidFuture())
        ready.whenComplete { [self] result in
            if case .failure(let error) = result { fail(error.localizedDescription, status: 502) }
            else if isProcessing { channel.read() }
        }
    }
    func upstreamClosed(_ channel: Channel) {
        guard channel === upstream else { return }
        upstream = nil; upstreamTarget = nil
        if record != nil, isProcessing && !responseEnded { fail("上游连接提前关闭", status: 502) }
    }
    func upstreamError(_ error: Error, channel: Channel) {
        guard channel === upstream else { return }
        if record == nil { upstream = nil; upstreamTarget = nil; closeProxyChannel(channel) }
        else { fail(ProxyTLS.errorDescription(error), status: 502) }
    }

    func sendStatic(_ draft: HTTPMessageDraft) {
        guard let client else { return }
        responseStarted = true
        let headers = responseHeaders(draft)
        record?.status = draft.status; record?.responseHeaders = fields(headers)
        responseBodyCollector = CaptureBodyCollector(headers: fields(headers))
        if record?.captureProtocol == .sse || isSSE(fields(headers)) {
            record?.captureProtocol = .sse
            let stream = CaptureStreamStore(contentEncoding: headers["content-encoding"].first)
            record?.stream = stream
            if let body = draft.replacementBytes { appendSSE(client.allocator.buffer(bytes: body), to: stream) }
        }
        trackResponseWrite(client.write(HTTPServerResponsePart.head(HTTPResponseHead(version: messageVersion, status: .init(statusCode: draft.status), headers: headers))))
        if allowsBody(draft.status), let body = draft.replacementBytes {
            record?.responseBytes = body.count
            responseBodyCollector?.append(body)
            trackResponseWrite(client.write(HTTPServerResponsePart.body(.byteBuffer(client.allocator.buffer(bytes: body)))))
        }
        writeResponseEnd(nil).whenComplete { [self] result in
            if case .failure(let error) = result { finish(error: error.localizedDescription) }
            else { responseWriteComplete = !responseWriteFailed; finish() }
            closeProxyChannel(client)
        }
    }
    func responseHeaders(_ draft: HTTPMessageDraft, keepAlive: Bool = false) -> HTTPHeaders {
        var headers = cleanHeaders(draft.headers)
        headers.remove(name: "Content-Length"); headers.remove(name: "Transfer-Encoding")
        if !isHTTP2 { headers.replaceOrAdd(name: "Connection", value: keepAlive ? "keep-alive" : "close") }
        if let body = draft.replacementBytes, draft.status != 204, draft.status != 205, draft.status != 304 {
            headers.replaceOrAdd(name: "Content-Length", value: String(body.count))
        } else if !isHTTP2 && allowsBody(draft.status) { headers.replaceOrAdd(name: "Transfer-Encoding", value: "chunked") }
        return headers
    }
    func allowsBody(_ status: Int) -> Bool { originalMethod != "HEAD" && status != 204 && status != 205 && status != 304 }
    func sendBufferedResponse(_ draft: HTTPMessageDraft) {
        guard let client, isProcessing else { return }
        response = draft; responseStarted = true
        let bytes = draft.replacementBytes ?? scriptResponseBytes
        scriptResponseBytes = Data()
        var headers = responseHeaders(draft)
        headers.remove(name: "Transfer-Encoding")
        if allowsBody(draft.status) { headers.replaceOrAdd(name: "Content-Length", value: String(bytes.count)) }
        record?.status = draft.status; record?.responseHeaders = fields(headers)
        responseBodyCollector = CaptureBodyCollector(headers: fields(headers))
        trackResponseWrite(client.write(HTTPServerResponsePart.head(HTTPResponseHead(version: messageVersion, status: .init(statusCode: draft.status), headers: headers))))
        if allowsBody(draft.status) {
            responseBodyCollector?.append(bytes)
            trackResponseWrite(client.write(HTTPServerResponsePart.body(.byteBuffer(client.allocator.buffer(bytes: bytes)))))
        }
        let trailers = isHTTP2 && !draft.hasReplacementBody ? responseTrailers : nil
        record?.responseTrailers = trailers.map(fields)
        writeResponseEnd(trailers).whenComplete { [self] result in
            if case .failure(let error) = result { finish(error: error.localizedDescription) }
            else { responseWriteComplete = !responseWriteFailed; finish() }
            closeProxyChannel(client)
            if let upstream { closeProxyChannel(upstream) }
        }
    }

}
