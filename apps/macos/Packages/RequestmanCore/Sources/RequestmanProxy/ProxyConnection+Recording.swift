import Foundation
import NIOCore
import NIOHTTP1
import RequestmanCore

extension ProxyConnection {
    func fail(_ message: String, status: Int) {
        guard isProcessing else { return }
        failureMessage = message
        transaction?.cancel()
        suspendedFlowControl?.cancel()
        scriptLease?.control.cancel()
        timer?.cancel(); certificateTask?.cancel()
        if let upstream { closeProxyChannel(upstream) }
        guard let client else { finish(error: message); return }
        if responseStarted || tunnel { finish(error: message); closeProxyChannel(client); return }
        record?.status = status
        responseStarted = true
        let body = "Requestman: \(message)"
        var headers = HTTPHeaders([("Connection", "close"), ("Content-Type", "text/plain; charset=utf-8"), ("Content-Length", String(body.utf8.count))])
        if isHTTP2 { headers.remove(name: "Connection") }
        record?.responseHeaders = fields(headers)
        responseBodyCollector = CaptureBodyCollector(headers: fields(headers))
        trackResponseWrite(client.write(HTTPServerResponsePart.head(HTTPResponseHead(version: messageVersion, status: .init(statusCode: status), headers: headers))))
        if originalMethod != "HEAD" {
            responseBodyCollector?.append(body.utf8)
            trackResponseWrite(client.write(HTTPServerResponsePart.body(.byteBuffer(client.allocator.buffer(string: body)))))
        }
        writeResponseEnd(nil).whenComplete { [self] result in
            if case .success = result { responseWriteComplete = !responseWriteFailed }
            finish(error: message)
            closeProxyChannel(client)
        }
    }
    func finish(error: String? = nil) {
        guard !finished else { return }
        finished = true; timer?.cancel(); recordTimer?.cancel(); recordTimer = nil; certificateTask?.cancel()
        let acceptsLateTrace = suspendedFlowControl != nil
        transaction?.cancel()
        suspendedFlowControl?.cancel(); suspendedFlowControl = nil
        scriptLease?.control.cancel()
        scriptLease = nil; scriptRequestHead = nil; scriptRequestDraft = nil; scriptResponseDraft = nil
        scriptRequestBytes = Data(); scriptResponseBytes = Data(); readingResponseBodyFile = false
        pending.removeAll()
        guard !recordOwnershipTransferred, var record else { return }
        let elapsed = started.duration(to: .now).components
        record.duration = Double(elapsed.attoseconds) / 1e18 + Double(elapsed.seconds)
        record.error = failureMessage ?? error
        if let requestBodyCollector { record.requestBody = requestBodyCollector.snapshot(isComplete: requestEnded) }
        if let sentBodyCollector { record.sentBody = sentBodyCollector.snapshot(isComplete: requestWriteComplete) }
        if let receivedBodyCollector { record.receivedBody = receivedBodyCollector.snapshot(isComplete: responseEnded) }
        if let responseBodyCollector { record.responseBody = responseBodyCollector.snapshot(isComplete: responseWriteComplete) }
        if record.error != nil { record.outcome = .failed }
        else if record.outcome == .forwarded && !record.steps.isEmpty { record.outcome = .modified }
        record.connectionState = record.error == nil ? .closed : .failed
        replaySession?.complete(&record)
        shared.events.append(.init(shared.isStopping || record.replayCancelled ? .cancelled : (record.error == nil ? .completed : .failed),
            transactionID: record.id, workflowID: record.matchedWorkflowID, message: record.error))
        record.revision &+= 1
        let finalRecord = record, generation = recordGeneration, records = records, recorder = traceRecorder
        let publish: @Sendable () -> Void = {
            if let recorder { recorder.publishFinal(finalRecord, acceptsLateTrace: acceptsLateTrace) }
            else { records.append(finalRecord, generation: generation) }
        }
        if let lastStreamWrite { lastStreamWrite.whenComplete { _ in publish() } }
        else { publish() }
    }

    func startRecordUpdates() {
        guard let client, recordTimer == nil else { return }
        publishRecord()
        recordTimer = client.eventLoop.scheduleTask(in: .milliseconds(200)) { [self] in
            recordTimer = nil
            if isProcessing { startRecordUpdates() }
        }
    }
    func publishRecord() {
        guard record != nil else { return }
        if !records.isCurrent(recordGeneration) {
            record?.stream = nil; record?.receivedStream = nil
            requestBodyCollector = nil; sentBodyCollector = nil; receivedBodyCollector = nil; responseBodyCollector = nil
        }
        let elapsed = started.duration(to: .now).components
        record?.duration = Double(elapsed.attoseconds) / 1e18 + Double(elapsed.seconds)
        record?.revision &+= 1
        if requestEnded, let requestBodyCollector { record?.requestBody = requestBodyCollector.snapshot(isComplete: true) }
        if requestWriteComplete, let sentBodyCollector { record?.sentBody = sentBodyCollector.snapshot(isComplete: true) }
        if let record { records.append(record, generation: recordGeneration) }
    }
}
