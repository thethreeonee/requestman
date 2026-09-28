import Foundation
import Testing
@testable import RequestmanCore

struct RequestLogColumnsTests {
    @Test func headerStagesRemainIndependentAndKeepRepeatedValues() {
        var record = CaptureRecord(method: "GET", url: "https://example.test")
        record.requestHeaders = [.init("X-ID", "one"), .init("x-id", "two")]
        record.sentHeaders = [.init("X-ID", "sent")]
        record.receivedHeaders = [.init("X-ID", "upstream")]
        record.responseHeaders = [.init("X-ID", "returned")]
        var column = RequestLogExtraColumn(name: " x-Id ")
        #expect(column.value(in: record) == "one\ntwo")
        column.stage = .sentRequest; #expect(column.value(in: record) == "sent")
        column.stage = .originalResponse; #expect(column.value(in: record) == "upstream")
        column.stage = .returnedResponse; #expect(column.value(in: record) == "returned")
        record.responseHeaders = []; #expect(column.value(in: record) == nil)
        record.responseHeaders = [.init("X-ID", "")]
        #expect(column.value(in: record) == "")
    }

    @Test func queryParametersRespectStageCaseEncodingDuplicatesAndEmptyValues() {
        var record = CaptureRecord(method: "GET", url: "https://example.test/p?tag=a%26b&Tag=other&tag=c+d&empty=&flag")
        record.finalURL = "https://rewritten.test/new?tag=sent%20value"
        var column = RequestLogExtraColumn(field: .queryParameter, name: "tag")
        #expect(column.value(in: record) == "a&b\nc+d")
        column.name = "Tag"; #expect(column.value(in: record) == "other")
        column.name = "empty"; #expect(column.value(in: record) == "")
        column.name = "flag"; #expect(column.value(in: record) == "")
        column.name = "missing"; #expect(column.value(in: record) == nil)
        column.name = "tag"; column.stage = .sentRequest
        #expect(column.value(in: record) == nil)
        record.hasSentRequestHeaders = true
        #expect(column.value(in: record) == "sent value")
        record.finalURLWasTruncated = true; #expect(column.value(in: record) == nil)
    }

    @Test func scalarFieldsUseTheSelectedSnapshotWithoutFallback() {
        var record = CaptureRecord(method: "GET", url: "https://example.test/a%2Fb?q=1")
        record.sentMethod = "POST"; record.finalURL = "http://rewritten.test/new"
        record.hasSentRequestHeaders = true
        record.originalStatus = 502; record.status = 200
        #expect(RequestLogExtraColumn(field: .url).value(in: record) == record.url)
        #expect(RequestLogExtraColumn(field: .host).value(in: record) == "example.test")
        #expect(RequestLogExtraColumn(field: .path).value(in: record) == "/a%2Fb")
        #expect(RequestLogExtraColumn(field: .method, stage: .sentRequest).value(in: record) == "POST")
        #expect(RequestLogExtraColumn(field: .url, stage: .sentRequest).value(in: record) == record.finalURL)
        #expect(RequestLogExtraColumn(field: .status, stage: .originalResponse).value(in: record) == "502")
        #expect(RequestLogExtraColumn(field: .status, stage: .returnedResponse).value(in: record) == "200")
        record.originalStatus = nil
        #expect(RequestLogExtraColumn(field: .status, stage: .originalResponse).value(in: record) == nil)
    }

    @Test func validationRejectsUnsupportedStageAndInvalidHeaderNames() {
        #expect(RequestLogExtraColumn(name: "Content-Type").validationError == nil)
        #expect(RequestLogExtraColumn(name: "bad name").validationError != nil)
        #expect(RequestLogExtraColumn(name: "中文").validationError != nil)
        #expect(RequestLogExtraColumn(field: .queryParameter, name: " ").validationError != nil)
        #expect(RequestLogExtraColumn(field: .queryParameter, stage: .originalResponse, name: "page").validationError != nil)
        #expect(RequestLogExtraColumn(field: .status).validationError != nil)
        #expect(RequestLogExtraColumn(field: .method, title: " 方法 ").displayTitle == "方法")
    }

    @Test func legacyHeaderMigratesOnceWithStableIdentityAndVisibility() {
        let legacy: [String: Any] = ["columns": ["request", "device"], "headerName": "X-Trace",
                                     "headerEnabled": false, "headerSource": "originalResponse"]
        let options = RequestLogDisplayOptions(preferences: legacy)
        #expect(options.extraColumns.count == 1)
        #expect(options.extraColumns.first?.id == RequestLogExtraColumn.legacyHeaderID)
        #expect(options.extraColumns.first?.stage == .originalResponse)
        #expect(options.extraColumns.first?.isEnabled == false)
        #expect(!options.isVisible(.device, allowLAN: false))
        #expect(options.isVisible(.device, allowLAN: true))
        #expect(RequestLogDisplayOptions(preferences: options.preferences) == options)
        var removed = options; removed.extraColumns = []
        #expect(RequestLogDisplayOptions(preferences: removed.preferences).extraColumns.isEmpty)
    }

    @Test func orderSurvivesRenamesHidingRemovalAndAddingMultipleColumns() {
        var options = RequestLogDisplayOptions()
        let header = RequestLogExtraColumn(name: "X-ID")
        let query = RequestLogExtraColumn(field: .queryParameter, name: "page")
        options.extraColumns = [header, query]
        #expect(Array(options.orderedColumnIDs[2...4]) == ["request", header.identifier, query.identifier])
        options.columnOrder = ["duration", query.identifier, "request", "time", "status", header.identifier, "rules", "device"]
        options.extraColumns[0].title = "Trace"
        options.extraColumns[1].isEnabled = false
        let restored = RequestLogDisplayOptions(preferences: options.preferences)
        #expect(restored.orderedColumnIDs == options.columnOrder)
        #expect(restored.extraColumns == options.extraColumns)
        options.extraColumns.removeFirst()
        #expect(!options.orderedColumnIDs.contains(header.identifier))
        let method = RequestLogExtraColumn(field: .method)
        options.extraColumns.append(method)
        #expect(options.orderedColumnIDs.firstIndex(of: method.identifier) == 2)
        options.columnOrder += ["time", "unknown"]
        #expect(Set(options.orderedColumnIDs).count == options.orderedColumnIDs.count)
        #expect(!options.orderedColumnIDs.contains("unknown"))
    }

    @Test func invalidPreferencesKeepAtLeastOneStandardColumnAndDeduplicateExtras() {
        let extra = RequestLogExtraColumn(name: "X-ID")
        var options = RequestLogDisplayOptions(); options.extraColumns = [extra]
        var saved = options.preferences
        let item = (saved["extraColumns"] as! [[String: Any]])[0]
        saved["columns"] = ["device", "unknown"]
        saved["extraColumns"] = [item, item, ["id": "broken"]]
        let restored = RequestLogDisplayOptions(preferences: saved)
        #expect(restored.columns.contains(.request))
        #expect(restored.extraColumns == [extra])
    }
}
