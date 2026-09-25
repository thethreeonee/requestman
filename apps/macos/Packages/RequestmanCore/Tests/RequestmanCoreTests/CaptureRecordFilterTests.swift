import Foundation
import Testing
@testable import RequestmanCore

struct CaptureRecordFilterTests {
    private func record() -> CaptureRecord {
        var record = CaptureRecord(method: "POST", url: "https://example.test/orders")
        record.requestHeaders = [HTTPField("Content-Type", "application/json"), HTTPField("X-Tag", "Alpha"), HTTPField("X-Tag", "Beta")]
        record.sentHeaders = [HTTPField("Content-Type", "text/plain")]
        record.hasSentRequestHeaders = true
        record.project = "商城"; record.environment = "dev"; record.outcome = .modified
        return record
    }
    @Test func originalAndSentHeadersUseIndependentSnapshots() {
        let record = record()
        var filter = CaptureRecordFilter()
        filter.headers = [.init(name: " content-TYPE ", value: "json")]
        #expect(filter.matches(record))
        filter.headerSource = .sent
        #expect(!filter.matches(record))
        filter.headers[0].value = "plain"
        #expect(filter.matches(record))
        var unavailable = record; unavailable.hasSentRequestHeaders = false
        filter.inverted = true
        #expect(!filter.matches(unavailable))
    }
    @Test func duplicateValuesAndCaseSensitiveValueMatching() {
        var filter = CaptureRecordFilter()
        filter.headers = [.init(name: "x-tag", operation: .equals, value: "Beta")]
        #expect(filter.matches(record()))
        filter.headers[0].value = "beta"
        #expect(!filter.matches(record()))
        filter.headers[0].operation = .exists
        #expect(filter.matches(record()))
        filter.headers[0] = .init(name: "x-missing", operation: .absent)
        #expect(filter.matches(record()))
    }
    @Test func allAnyAndInversion() {
        var filter = CaptureRecordFilter()
        filter.headers = [.init(name: "content-type", value: "json"), .init(name: "x-missing", operation: .exists)]
        #expect(!filter.matches(record()))
        filter.headerCombination = .any
        #expect(filter.matches(record()))
        filter.inverted = true
        #expect(!filter.matches(record()))
        filter.project = "其他项目"
        #expect(filter.matches(record()))
        filter = CaptureRecordFilter(); filter.inverted = true
        #expect(filter.matches(record()), "Inversion alone must not hide the entire log")
    }
    @Test func authorizationValuesCanBeFilteredAndInverted() {
        var record = record(); record.requestHeaders.append(HTTPField("Authorization", "Bearer secret"))
        record = record.bounded()
        var filter = CaptureRecordFilter()
        filter.headers = [.init(name: "authorization", operation: .equals, value: "Bearer secret")]
        #expect(filter.matches(record))
        filter.inverted = true
        #expect(!filter.matches(record))
        filter.headers[0].value = "other"
        #expect(filter.matches(record))
    }
    @Test func truncatedValuesAndMissingFieldsRemainUnknown() {
        var record = record()
        record.requestHeaders = (0..<41).map { HTTPField("X-\($0)", "value") }
        record.requestHeaders[0] = HTTPField("X-Long", String(repeating: "a", count: 300))
        // An explicitly incomplete snapshot must remain unknown, even without automatic value truncation.
        record.requestHeadersInfo.truncatedNames = ["x-long"]
        record.requestHeadersInfo.isTruncated = true
        record.requestHeaders.removeLast()
        record = record.bounded()
        var filter = CaptureRecordFilter()
        filter.headers = [.init(name: "X-Long", value: "a")]
        #expect(!filter.matches(record))
        filter.inverted = true
        #expect(!filter.matches(record))
        filter.headers = [.init(name: "X-40", operation: .absent)]
        #expect(!filter.matches(record))
        filter.inverted = false
        #expect(!filter.matches(record))
        filter.headers = [.init(name: "X-1", operation: .exists)]
        #expect(filter.matches(record))
    }
    @Test func combinationsCanResolveWithUnknownEvidence() {
        var record = record(); record.requestHeaders.append(HTTPField("X-Partial", "prefix"))
        record.requestHeadersInfo.truncatedNames = ["x-partial"]; record = record.bounded()
        var filter = CaptureRecordFilter()
        filter.headers = [.init(name: "X-Partial", value: "prefix"), .init(name: "X-Tag", value: "Alpha")]
        #expect(!filter.matches(record))
        filter.headerCombination = .any
        #expect(filter.matches(record))
        filter.headerCombination = .all; filter.headers[1].value = "not-present"; filter.inverted = true
        #expect(filter.matches(record))
    }
    @Test func longCookieValuesRemainSearchableInBothSnapshots() {
        var record = record()
        let prefix = "session=" + String(repeating: "a", count: 8_192)
        record.requestHeaders = [HTTPField("Cookie", prefix + "; source=original")]
        record.sentHeaders = [HTTPField("Cookie", prefix + "; source=modified")]
        record = record.bounded().bounded()
        #expect(!record.requestHeadersInfo.isTruncated && !record.sentHeadersInfo.isTruncated)
        var filter = CaptureRecordFilter()
        filter.headers = [.init(name: "Cookie", value: "source=original")]
        #expect(filter.matches(record))
        filter.headerSource = .sent
        #expect(!filter.matches(record))
        filter.headers[0].value = "source=modified"
        #expect(filter.matches(record))
    }
    @Test func emptyDraftsAndEncryptedTunnels() {
        var filter = CaptureRecordFilter()
        filter.headers = [.init(), .init(name: "content-type")]
        #expect(filter.activeConditionCount == 0)
        #expect(filter.matches(record()))
        var tunnel = CaptureRecord(method: "CONNECT", url: "example.test:443"); tunnel.outcome = .tunnel
        filter.headers = [.init(name: "content-type", operation: .absent)]
        #expect(!filter.matches(tunnel))
        filter.inverted = true
        #expect(!filter.matches(tunnel))
    }
    @Test func metadataAndResourcesCombineWithHeaders() {
        var record = record()
        record.responseHeaders = [HTTPField("Content-Type", "application/problem+json; charset=utf-8")]
        record.matchedRules = [.init(kind: .setHeader, name: "登录调试", response: false)]
        var filter = CaptureRecordFilter()
        filter.resource = .json; filter.project = "商城"; filter.environment = "dev"; filter.method = "POST"
        filter.search = "登录调试"; filter.outcome = .modified
        filter.headers = [.init(name: "content-type", value: "json")]
        #expect(filter.matches(record))
        #expect(filter.activeConditionCount == 5)
        filter.method = "GET"
        #expect(!filter.matches(record))
        record.finalURL = "https://example.test/test.png"
        #expect(CaptureResourceType.classify(record) == .json)
        record.responseHeaders = []
        #expect(CaptureResourceType.classify(record) == .image)
        record.responseHeaders = [HTTPField("Content-Type", "text/plain")]
        #expect(CaptureResourceType.classify(record) == .other)
    }
    @Test func executedRuleCallbackExcludesDisabledSkippedAndFailedActions() throws {
        var disabled = ModificationStep(kind: .setHeader); disabled.enabled = false
        var mock = ModificationStep(kind: .mock); mock.value = "{}"
        var after = ModificationStep(kind: .setHeader); after.name = "X-After"; after.value = "yes"
        var draft = HTTPMessageDraft(method: "GET", url: "https://example.test/")
        var executed: [ModificationKind] = []
        _ = try WorkflowEngine.apply([disabled, mock, after], response: false, to: &draft, environment: [:], id: UUID(), date: Date()) { executed.append($0) }
        #expect(executed == [.mock])
        var invalid = ModificationStep(kind: .setHeader); invalid.name = "Bad Name"
        #expect(throws: WorkflowError.self) {
            _ = try WorkflowEngine.apply([after, invalid], response: true, to: &draft, environment: [:], id: UUID(), date: Date()) { executed.append($0) }
        }
        #expect(executed == [.mock, .setHeader])
    }
}
