import Foundation
import NIOCore
import RequestmanCore
import os

/// Replay identity travels through the local socket association, never through HTTP headers.
final class ProxyReplaySession: Sendable {
    let request: RequestReplayDraft
    let generation: UInt64
    private let records: CaptureRecordBuffer
    private struct State {
        var client: Channel?
        var downstream: Channel?
        var cancelled = false
        var cancellationReason = "用户取消重放"
        var finished = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    init(request: RequestReplayDraft, records: CaptureRecordBuffer) {
        self.request = request; self.records = records; generation = records.generation
    }
    var clientPort: Int? { state.withLock { $0.client?.localAddress?.port } }
    var isCancelled: Bool { state.withLock { $0.cancelled } }
    func attach(_ channel: Channel, downstream: Bool = false) {
        let close = state.withLock {
            if downstream { $0.downstream = channel } else { $0.client = channel }
            return $0.cancelled
        }
        if close { channel.close(promise: nil) }
    }
    func cancel(reason: String = "用户取消重放") {
        let channels: [Channel] = state.withLock {
            guard !$0.finished else { return [] }
            $0.cancelled = true; $0.cancellationReason = reason
            return [$0.downstream, $0.client].compactMap { $0 }
        }
        for channel in channels { channel.close(promise: nil) }
    }
    /// Called by the proxy before publishing the authoritative terminal record.
    func complete(_ record: inout CaptureRecord) {
        record.replayCancelled = state.withLock {
            $0.finished = true
            return $0.cancelled
        }
        if record.replayCancelled {
            record.error = nil
            if record.outcome == .failed { record.outcome = record.steps.isEmpty ? .forwarded : .modified }
            record.closeReason = state.withLock { $0.cancellationReason }; record.connectionState = .closed
        }
    }
    /// Covers rejection before request decoding and a client transport failure.
    func clientClosed() {
        let downstream: Channel? = state.withLock { $0.finished ? nil : $0.downstream }
        if let downstream {
            downstream.close(promise: nil)
            downstream.closeFuture.whenComplete { [self] _ in publishFallback() }
        } else { publishFallback() }
    }
    func publishFallback(error: String = "重放连接在响应完成前关闭") {
        let cancelled: Bool? = state.withLock {
            guard !$0.finished else { return nil }
            $0.finished = true
            return $0.cancelled
        }
        guard let cancelled else { return }
        var record = CaptureRecord(id: request.id, method: request.method, url: request.url)
        record.replayID = request.id; record.replaySourceID = request.sourceRecordID
        record.replayCancelled = cancelled
        record.connectionState = cancelled ? .closed : .failed
        record.error = cancelled ? nil : error
        record.outcome = cancelled ? .forwarded : .failed
        record.closeReason = cancelled ? state.withLock { $0.cancellationReason } : nil
        records.append(record, generation: generation)
    }
}
