import Foundation
import Testing
@testable import RequestmanCore

struct RequestLogSearchTests {
    private func matches(_ query: String, _ record: CaptureRecord, columns: Set<RequestLogStandardColumn>,
                         showsMethod: Bool = false, extras: [RequestLogExtraColumn] = [], context: RequestLogSearchContext = .init()) -> Bool {
        var filter = CaptureRecordFilter(); filter.search = query
        var options = RequestLogDisplayOptions(); options.columns = columns; options.showsMethod = showsMethod; options.extraColumns = extras
        return filter.matches(record, displayOptions: options, searchContext: context)
    }

    @Test func standardColumnsSearchTheirDisplayedTextOnly() {
        var record = CaptureRecord(method: "POST", url: "https://example.test/items")
        record.startedAt = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 12, minute: 34, second: 56))!
        record.status = 418; record.duration = 1.234
        record.project = "商城调试组"; record.matchedWorkflowID = UUID(); record.workflow = "添加追踪"
        let queries: [(RequestLogStandardColumn, String)] = [
            (.time, "12:34:56"), (.status, "418"), (.request, "EXAMPLE.TEST/items"),
            (.rules, "商城"), (.rules, "添加追踪"), (.duration, "1.2 s")
        ]
        for (column, query) in queries {
            #expect(matches(query, record, columns: [column]))
            #expect(!matches(query, record, columns: Set(RequestLogStandardColumn.allCases).subtracting([column])))
        }
        record.duration = 0.125
        #expect(matches("125 ms", record, columns: [.duration]))
    }

    @Test func deviceSearchFollowsLANVisibilityAndCurrentAlias() {
        var record = CaptureRecord(method: "GET", url: "https://example.test")
        record.deviceSource = "192.168.1.8"
        var context = RequestLogSearchContext(allowLAN: true, deviceAliases: ["192.168.1.8": "测试手机"])
        #expect(matches("测试手机", record, columns: [.device], context: context))
        #expect(!matches("192.168.1.8", record, columns: [.device], context: context))
        context.allowLAN = false
        #expect(!matches("测试手机", record, columns: [.device], context: context))
        context.allowLAN = true; context.deviceAliases = [:]
        #expect(matches("192.168.1.8", record, columns: [.device], context: context))
        record.deviceSource = "local"
        #expect(matches("本机", record, columns: [.device], context: context))
    }

    @Test func ruleNamesFollowLiveRenamesButArchivesKeepCapturedNames() {
        var record = CaptureRecord(method: "GET", url: "https://example.test")
        let id = UUID(); record.matchedWorkflowID = id; record.workflow = "旧名称"
        let context = RequestLogSearchContext(workflowNames: [id: "新名称"])
        #expect(matches("新名称", record, columns: [.rules], context: context))
        #expect(!matches("旧名称", record, columns: [.rules], context: context))
        #expect(matches("旧名称", record, columns: [.rules]))
        record.archivedAt = Date()
        #expect(matches("旧名称", record, columns: [.rules], context: context))
        #expect(!matches("新名称", record, columns: [.rules], context: context))
    }

    @Test func extraColumnsRespectVisibilityStageAndRepeatedValues() {
        var record = CaptureRecord(method: "GET", url: "https://example.test/?q=decoded%20value")
        record.requestHeaders = [.init("X-Trace", "Alpha"), .init("X-Trace", "Beta")]
        record.responseHeaders = [.init("X-Trace", "Returned")]
        var column = RequestLogExtraColumn(name: "X-Trace")
        #expect(matches("beta", record, columns: [.status], extras: [column]))
        #expect(matches("Alpha · Beta", record, columns: [.status], extras: [column]))
        #expect(!matches("Returned", record, columns: [.status], extras: [column]))
        column.isEnabled = false
        #expect(!matches("Alpha", record, columns: [.status], extras: [column]))
        column.isEnabled = true; column.stage = .returnedResponse
        #expect(matches("returned", record, columns: [.status], extras: [column]))
        #expect(!matches("Alpha", record, columns: [.status], extras: [column]))
        column.name = "bad name"
        #expect(!matches("—", record, columns: [.request], extras: [column]))
        column = .init(field: .queryParameter, name: "q")
        #expect(matches("decoded value", record, columns: [.status], extras: [column]))
        #expect(!matches("example.test", record, columns: [.status], extras: [column]))
    }

    @Test func requestAndDurationSearchVisibleProtocolErrorAndConnectionText() {
        var record = CaptureRecord(method: "GET", url: "https://example.test")
        record.captureProtocol = .sse; record.error = "连接超时"
        #expect(matches("SSE", record, columns: [.request], showsMethod: true))
        #expect(!matches("GET", record, columns: [.request], showsMethod: true))
        #expect(matches("连接超时", record, columns: [.request]))
        record.connectionState = .connecting
        #expect(matches(record.connectionSummary, record, columns: [.duration]))
        #expect(!matches("0 ms", record, columns: [.duration]))
    }

    @Test func visibleSearchRetainsCombinedFiltersAndInversion() {
        var record = CaptureRecord(method: "POST", url: "https://example.test")
        record.status = 201
        var filter = CaptureRecordFilter(); filter.search = "201"; filter.method = "POST"
        var options = RequestLogDisplayOptions(); options.columns = [.status]
        #expect(filter.matches(record, displayOptions: options))
        filter.method = "GET"
        #expect(!filter.matches(record, displayOptions: options))
        filter.inverted = true
        #expect(filter.matches(record, displayOptions: options))
        filter.method = "POST"
        #expect(!filter.matches(record, displayOptions: options))
        filter.inverted = false; filter.search = ""
        options.columns = []
        #expect(filter.matches(record, displayOptions: options))
    }
    @Test func mergedFieldSearchFollowsDestinationAndIndependentURLStatusSwitches() {
        var record = CaptureRecord(method: "GET", url: "https://example.test")
        record.status = 204
        record.requestHeaders = [.init("X-ID", "trace-value")]
        var field = RequestLogExtraColumn(name: "X-ID", mergedInto: "request")
        #expect(matches("trace-value", record, columns: [.status], extras: [field]))
        #expect(!matches("example.test", record, columns: [.status], extras: [field]))
        #expect(!matches("204", record, columns: [.request], extras: [field]))
        #expect(!matches("trace-value", record, columns: [.time], extras: [field]))
        field.mergedInto = "device"
        #expect(!matches("trace-value", record, columns: [.device], extras: [field]))
        #expect(matches("trace-value", record, columns: [.device], extras: [field], context: .init(allowLAN: true)))
        let host = RequestLogExtraColumn(field: .host, isEnabled: false)
        field.mergedInto = host.identifier
        #expect(!matches("trace-value", record, columns: [.time], extras: [host, field]))
        field.mergedInto = nil
        #expect(matches("trace-value", record, columns: [.time], extras: [field]))
    }

    @Test func methodSearchIsIndependentOfURLAndKeepsMergedFieldsVisible() {
        let record = CaptureRecord(method: "POST", url: "https://example.test")
        #expect(matches("post", record, columns: [], showsMethod: true))
        #expect(!matches("post", record, columns: [.request], showsMethod: false))
        #expect(matches("example.test", record, columns: [.request], showsMethod: false))
        #expect(!matches("example.test", record, columns: [], showsMethod: true))
        #expect(matches("POST https://example.test", record, columns: [.request], showsMethod: true))
        let field = RequestLogExtraColumn(field: .host, mergedInto: "request")
        #expect(matches("example.test", record, columns: [], showsMethod: true, extras: [field]))
        #expect(!matches("example.test", record, columns: [], showsMethod: false, extras: [field]))
    }

}
