import Foundation
import os

public struct CaptureRecord: Identifiable, Sendable {
    public enum Outcome: String, CaseIterable, Sendable { case forwarded = "已转发", modified = "已修改", mocked = "Mock", tunnel = "加密隧道", failed = "失败" }
    public let id: UUID
    public var startedAt: Date
    public var method: String
    public var url: String
    public var finalURL: String
    public var sentMethod: String
    public var project = "未匹配"
    public var workflow = "直接转发"
    public var environment = "无环境"
    public var outcome: Outcome = .forwarded
    public var status: Int?
    public var duration: Double = 0
    public var requestBytes = 0
    public var responseBytes = 0
    public var requestHeaders: [HTTPField] = []
    public var sentHeaders: [HTTPField] = []
    public var responseHeaders: [HTTPField] = []
    public var receivedHeaders: [HTTPField] = []
    public var steps: [String] = []
    public var error: String?
    public init(id: UUID = UUID(), method: String, url: String) {
        self.id = id; self.method = method; self.sentMethod = method; self.url = url; self.finalURL = url; self.startedAt = Date()
    }
    /// No bodies in the history queue; bound strings and redact credential headers before insertion.
    public func bounded() -> Self {
        var copy = self
        copy.url = String(url.prefix(2048)); copy.finalURL = String(finalURL.prefix(2048))
        copy.project = String(project.prefix(128)); copy.workflow = String(workflow.prefix(128))
        copy.environment = String(environment.prefix(128)); copy.error = error.map { String($0.prefix(512)) }
        copy.steps = steps.prefix(64).map { String($0.prefix(128)) }
        copy.requestHeaders = Self.redact(requestHeaders); copy.sentHeaders = Self.redact(sentHeaders)
        copy.responseHeaders = Self.redact(responseHeaders); copy.receivedHeaders = Self.redact(receivedHeaders)
        return copy
    }
    private static func redact(_ fields: [HTTPField]) -> [HTTPField] {
        fields.prefix(40).map { field in
            let sensitive = ["authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key"].contains(field.name.lowercased())
            return HTTPField(String(field.name.prefix(128)), sensitive ? "••••••" : String(field.value.prefix(256)))
        }
    }
}

/// One bounded producer/consumer bridge; UI pulls at 5 Hz. Pausing history never pauses networking.
public final class CaptureRecordBuffer: Sendable {
    private struct State {
        var records: [CaptureRecord] = []
        var dropped = 0
        var paused = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    public let capacity: Int
    public init(capacity: Int = 256) { self.capacity = max(1, capacity) }
    public func append(_ record: CaptureRecord) {
        let bounded = record.bounded()
        state.withLock {
            guard !$0.paused else { return }
            if $0.records.count == capacity { $0.records.removeFirst(); $0.dropped += 1 }
            $0.records.append(bounded)
        }
    }
    public func drain(limit: Int = 64) -> (records: [CaptureRecord], dropped: Int) {
        state.withLock {
            let records = Array($0.records.prefix(max(1, limit)))
            $0.records.removeFirst(records.count)
            let dropped = $0.dropped; $0.dropped = 0
            return (records, dropped)
        }
    }
    public func setPaused(_ paused: Bool) { state.withLock { $0.paused = paused } }
    public func clear() { state.withLock { $0.records.removeAll(keepingCapacity: true); $0.dropped = 0 } }
}
