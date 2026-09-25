import Foundation
import os

/// An executed action and its workflow name, captured before later workspace edits.
public struct CaptureMatchedRule: Equatable, Sendable {
    public let kind: ModificationKind
    public let name: String
    public let response: Bool
    public init(kind: ModificationKind, name: String, response: Bool) {
        self.kind = kind; self.name = String(name.prefix(128)); self.response = response
    }
    public var typeName: String {
        switch kind {
        case .setHeader: response ? "修改响应头" : "修改请求头"
        case .removeHeader: response ? "移除响应头" : "移除请求头"
        case .replaceBody: response ? "替换响应体" : "替换请求体"
        case .mock: "Mock"
        default: kind.title
        }
    }
    public var summary: String { "\(typeName) · \(name)" }
}

public struct CaptureHeadersInfo: Sendable {
    public var originalCount = 0
    public var isTruncated = false
    public var truncatedNames: Set<String> = []
    public init() {}
}

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
    public var matchedWorkflowID: UUID?
    public var matchedRules: [CaptureMatchedRule] = []
    public var hasSentRequestHeaders = false
    public var originalStatus: Int?
    public var status: Int?
    public var duration: Double = 0
    public var requestBytes = 0
    public var responseBytes = 0
    public var requestHeaders: [HTTPField] = []
    public var sentHeaders: [HTTPField] = []
    public var responseHeaders: [HTTPField] = []
    public var receivedHeaders: [HTTPField] = []
    public var requestBody: CaptureBodySnapshot = .notCollected
    public var sentBody: CaptureBodySnapshot = .notCollected
    public var receivedBody: CaptureBodySnapshot = .notCollected
    public var responseBody: CaptureBodySnapshot = .notCollected
    public var urlWasTruncated = false
    public var finalURLWasTruncated = false
    public var requestHeadersInfo = CaptureHeadersInfo()
    public var sentHeadersInfo = CaptureHeadersInfo()
    public var receivedHeadersInfo = CaptureHeadersInfo()
    public var responseHeadersInfo = CaptureHeadersInfo()
    public var steps: [String] = []
    public var error: String?
    public init(id: UUID = UUID(), method: String, url: String) {
        self.id = id; self.method = method; self.sentMethod = method; self.url = url; self.finalURL = url; self.startedAt = Date()
    }
    /// Bound display metadata while retaining complete URL, Header and Body content.
    public func bounded() -> Self {
        var copy = self
        copy.project = String(project.prefix(128)); copy.workflow = String(workflow.prefix(128))
        copy.environment = String(environment.prefix(128)); copy.error = error.map { String($0.prefix(512)) }
        copy.steps = steps.prefix(64).map { String($0.prefix(128)) }
        copy.matchedRules = Array(matchedRules.prefix(128))
        copy.requestHeadersInfo.originalCount = max(requestHeadersInfo.originalCount, requestHeaders.count)
        copy.sentHeadersInfo.originalCount = max(sentHeadersInfo.originalCount, sentHeaders.count)
        copy.receivedHeadersInfo.originalCount = max(receivedHeadersInfo.originalCount, receivedHeaders.count)
        copy.responseHeadersInfo.originalCount = max(responseHeadersInfo.originalCount, responseHeaders.count)
        return copy
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
