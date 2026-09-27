import Foundation
import NIOCore
import NIOHTTP1
import RequestmanCore

extension ProxyConnection {
    func isSSE(_ headers: [HTTPField]) -> Bool {
        headers.contains { $0.name.lowercased() == "content-type" && $0.value.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "text/event-stream" }
    }
    func appendSSE(_ buffer: ByteBuffer, to stream: CaptureStreamStore) {
        guard records.isCurrent(recordGeneration), let client else { return }
        let promise = client.eventLoop.makePromise(of: Void.self)
        stream.appendSSE(Data(buffer.readableBytesView)) { promise.succeed(()) }
        lastStreamWrite = promise.futureResult
    }
    func receiveSSEHead(_ draft: HTTPMessageDraft) throws {
        record?.captureProtocol = .sse
        let stream = CaptureStreamStore(contentEncoding: draft.headers.first { $0.name.lowercased() == "content-encoding" }?.value)
        record?.receivedStream = stream
        record?.receivedBody = .unavailable("SSE 原始内容保存在事件流中")
        receivedBodyCollector = nil
        let steps = match?.workflow.responseSteps.filter(\.enabled) ?? []
        let replacement = steps.firstIndex { $0.kind == .replaceBody || $0.kind == .redirect }
        // Whole-body edits cannot read an endless response. A preceding replacement supplies a finite input.
        if let edit = steps.firstIndex(where: { PhaseExecutionRequirements(steps: [$0]).needsCompleteBody }), replacement == nil || edit < replacement! {
            throw WorkflowError.invalid("SSE 响应脚本或 JSON 修改需要在替换 Body 之后执行；暂不支持事件流内容修改")
        }
        if replacement != nil {
            if let channel = upstream { upstream = nil; upstreamTarget = nil; closeProxyChannel(channel) }
            record?.closeReason = "已取消上游并替换响应 Body"
            if transaction?.requirements(for: .response).requiresBackground == true {
                executeScriptFlow(response: true, draft: draft) { [self] in sendStatic($0) }
            } else {
                var reply = draft
                try applyRecordedSteps(response: true, to: &reply)
                sendStatic(reply)
            }
        } else if transaction?.requirements(for: .response).hasDelay == true {
            sseWaiting = true
            executeScriptFlow(response: true, draft: draft) { [self] result in
                sseWaiting = false
                startStreamingResponse(result)
                if let client {
                    for buffer in ssePending { trackResponseWrite(client.write(HTTPServerResponsePart.body(.byteBuffer(buffer)))) }
                }
                ssePending.removeAll()
                if let channel = upstream {
                    if responseEnded { endStreamingResponse(channel) } else { responseReadComplete(channel) }
                }
            }
        } else {
            var reply = draft
            try applyRecordedSteps(response: true, to: &reply)
            startStreamingResponse(reply)
        }
        publishRecord()
    }
}
