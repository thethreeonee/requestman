import Foundation
import NIOCore
import NIOHTTP1
import NIOWebSocket
import CryptoKit
import RequestmanCore

extension ProxyConnection {
    func upgradeWebSocket(_ head: HTTPResponseHead) throws {
        guard webSocketRequest, let client, let peer = upstream, var record else { throw WorkflowError.invalid("非 WebSocket 请求收到协议升级") }
        let key = record.sentHeaders.first { $0.name.lowercased() == "sec-websocket-key" }?.value ?? ""
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        let offered = record.sentHeaders.filter { $0.name.lowercased() == "sec-websocket-protocol" }
            .flatMap { $0.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        let protocols = head.headers["sec-websocket-protocol"]
        guard head.headers["sec-websocket-accept"] == [accept], headerTokens(head.headers, name: "connection").contains("upgrade"),
              headerTokens(head.headers, name: "upgrade") == ["websocket"], head.headers["sec-websocket-extensions"].isEmpty,
              protocols.isEmpty || protocols.count == 1 && offered.contains(protocols[0]) else {
            throw WorkflowError.invalid("上游 WebSocket 握手校验失败")
        }
        let steps = match?.workflow.responseSteps.filter(\.enabled) ?? []
        guard steps.allSatisfy({ [.setHeader, .removeHeader].contains($0.kind) }) else {
            throw WorkflowError.invalid("WebSocket 握手响应仅支持修改 Header；消息修改尚未实现")
        }
        record.receivedHeaders = fields(head.headers); record.originalStatus = 101
        var draft = HTTPMessageDraft(method: "GET", url: record.finalURL, status: 101, headers: record.receivedHeaders)
        try applyRecordedSteps(response: true, to: &draft)
        var headers = cleanHeaders(draft.headers)
        headers.remove(name: "Content-Length"); headers.remove(name: "Transfer-Encoding")
        headers.remove(name: "Sec-WebSocket-Extensions"); headers.remove(name: "Sec-WebSocket-Protocol")
        if let selected = protocols.first { headers.replaceOrAdd(name: "Sec-WebSocket-Protocol", value: selected) }
        headers.replaceOrAdd(name: "Connection", value: "Upgrade"); headers.replaceOrAdd(name: "Upgrade", value: "websocket")
        headers.replaceOrAdd(name: "Sec-WebSocket-Accept", value: accept)
        record.responseHeaders = fields(headers); record.status = 101
        record.executionTrace = self.record?.executionTrace ?? []
        record.steps = self.record?.steps ?? []; record.matchedRules = self.record?.matchedRules ?? []
        if !record.steps.isEmpty { record.outcome = .modified }
        self.record = record
        responseStarted = true; webSocketUpgrading = true
        let session = WebSocketSession(client: client, server: peer, record: record, records: records, generation: recordGeneration, shared: shared)
        // From this point the WebSocket session owns every terminal record, including upgrade failure.
        recordOwnershipTransferred = true
        recordTimer?.cancel(); recordTimer = nil
        // Install frame handlers before releasing decoder leftovers on either hop.
        client.writeAndFlush(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: .switchingProtocols, headers: headers)))
            .flatMap { [self] in client.pipeline.removeHandler(self) }
            .flatMap { client.pipeline.removeHTTPHandler(HTTPResponseEncoder.self) }
            .flatMap { peer.pipeline.removeHTTPHandler(ProxyResponseHandler.self) }
            .flatMap { peer.pipeline.removeHTTPHandler(NIOHTTPRequestHeadersValidator.self) }
            .flatMap { peer.pipeline.removeHTTPHandler(HTTPRequestEncoder.self) }
            .flatMap {
                client.eventLoop.makeCompletedFuture {
                    try client.pipeline.syncOperations.addHandlers([
                        WebSocketFrameEncoder(), ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize: Int(UInt32.max))),
                        WebSocketRelay(peer: peer, direction: .sent, session: session)
                    ])
                    try peer.pipeline.syncOperations.addHandlers([
                        WebSocketFrameEncoder(), ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize: Int(UInt32.max))),
                        WebSocketRelay(peer: client, direction: .received, session: session)
                    ])
                }
            }.flatMap { client.pipeline.removeHTTPHandler(ByteToMessageHandler<HTTPRequestDecoder>.self) }
            .flatMap { peer.pipeline.removeHTTPHandler(ByteToMessageHandler<HTTPResponseDecoder>.self) }
            .whenComplete { [self] result in
                switch result {
                case .failure(let error): session.finish(error: error.localizedDescription); finish(error: error.localizedDescription)
                case .success:
                    finished = true; timer?.cancel(); recordTimer?.cancel(); recordTimer = nil
                    self.upstream = nil; self.client = nil
                    session.start(); client.read(); peer.read()
                }
            }
    }

}
