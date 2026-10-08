import Foundation
import Testing
@testable import RequestmanCore

struct RequestLogLayoutTests {
    private func column(_ lines: [[RequestLogLayoutContent]]) -> RequestLogLayoutColumn {
        .init(title: "测试列", lines: lines.map { .init(contents: $0) })
    }

    @Test func emptyContentAndEntireEmptyLinesCollapseWithoutChangingRemainingOrder() {
        var record = CaptureRecord(method: "GET", url: "https://example.test/?empty=&empty=&flag")
        record.requestHeaders = [.init("X-Empty", ""), .init("X-Repeated", ""), .init("X-Repeated", "")]
        let configured = column([
            [.init(field: .status, stage: .returnedResponse), .init(field: .header, name: "X-Missing")],
            [.init(field: .header, name: "X-Empty"), .init(field: .queryParameter, name: "flag")],
            [.init(field: .header, name: "X-Repeated"), .init(field: .queryParameter, name: "empty")],
            [.init(field: .method), .init(field: .url)],
            [.init(field: .header, name: "X-Empty", emptyBehavior: .customText, emptyText: "无追踪信息")]
        ])
        let row = RequestLogRow(record: record)
        let displayed = row.renderedLines(in: configured, allowLAN: false)
        #expect(displayed.map(\.id) == [configured.lines[3].id, configured.lines[4].id])
        #expect(displayed[0].contents.map(\.text) == ["GET", record.url])
        #expect(displayed[1].contents.map(\.text) == ["无追踪信息"])
    }

    @Test func customEmptyTextDoesNotReplacePresentValuesAndEmptyCustomTextStaysHidden() {
        var record = CaptureRecord(method: "GET", url: "https://example.test")
        record.requestHeaders = [.init("X-ID", "captured"), .init("X-Space", " ")]
        let configured = column([[
            .init(field: .header, name: "X-ID", horizontalAlignment: .right, verticalAlignment: .bottom,
                  emptyBehavior: .customText, emptyText: "fallback"),
            .init(field: .header, name: "X-Missing", emptyBehavior: .customText),
            .init(field: .header, name: "X-Space")
        ]])
        let contents = RequestLogRow(record: record).renderedLines(in: configured, allowLAN: false)[0].contents
        #expect(contents.map(\.text) == ["captured", " "])
        #expect(contents[0].configuration.horizontalAlignment == .right)
        #expect(contents[0].configuration.verticalAlignment == .bottom)
    }

    @Test func rulesCanOccupyIndependentLinesAndCombinedContentKeepsCurrentNames() {
        var record = CaptureRecord(method: "GET", url: "https://example.test")
        let ruleID = UUID(); record.matchedWorkflowID = ruleID
        record.project = "商城调试"; record.workflow = "旧规则名称"
        let context = RequestLogSearchContext(workflowNames: [ruleID: "当前规则名称"])
        let configured = column([
            [.init(field: .ruleGroup)], [.init(field: .rule)], [.init(field: .rules)]
        ])
        let live = RequestLogRow(record: record, context: context).renderedLines(in: configured, allowLAN: false)
        #expect(live.map { $0.contents.map(\.text) } == [["商城调试"], ["当前规则名称"], ["商城调试\n当前规则名称"]])
        record.archivedAt = Date()
        let archived = RequestLogRow(record: record, context: context).renderedLines(in: configured, allowLAN: false)
        #expect(archived[1].contents.map(\.text) == ["旧规则名称"])
        #expect(archived[2].contents.map(\.text) == ["商城调试\n旧规则名称"])
    }

    @Test func unmatchedRulesAndMissingDeviceAreEmptyValues() {
        let record = CaptureRecord(method: "GET", url: "https://example.test")
        let configured = column([
            [.init(field: .ruleGroup), .init(field: .rule), .init(field: .rules)],
            [.init(field: .device)],
            [.init(field: .rules, emptyBehavior: .customText, emptyText: "未命中")]
        ])
        let displayed = RequestLogRow(record: record).renderedLines(in: configured, allowLAN: true)
        #expect(displayed.count == 1)
        #expect(displayed[0].contents.map(\.text) == ["未命中"])
    }

    @Test func LANDisabledSuppressesDeviceEvenWithFallbackButLeavesOtherContentVisible() {
        var record = CaptureRecord(method: "GET", url: "https://example.test")
        record.deviceSource = "192.168.1.8"
        let configured = column([[
            .init(field: .device, emptyBehavior: .customText, emptyText: "设备不可用"), .init(field: .method)
        ]])
        let deviceOnly = column([[.init(field: .device, emptyBehavior: .customText, emptyText: "设备不可用")]])
        var options = RequestLogDisplayOptions(); options.layoutColumns = [configured, deviceOnly]
        let context = RequestLogSearchContext(deviceAliases: ["192.168.1.8": "测试手机"])
        let row = RequestLogRow(record: record, displayOptions: options, context: context)
        #expect(options.visibleColumnIDs(allowLAN: false) == [configured.id])
        #expect(row.renderedLines(in: configured, allowLAN: false)[0].contents.map(\.text) == ["GET"])
        #expect(row.renderedLines(in: deviceOnly, allowLAN: false).isEmpty)
        #expect(!row.contains("测试手机", displayOptions: options, allowLAN: false))
        #expect(!row.contains("设备不可用", displayOptions: options, allowLAN: false))
        #expect(row.contains("测试手机", displayOptions: options, allowLAN: true))
    }

    @Test func stagedValuesNeverFallBackAndRepeatedCapturedValuesRetainNewlines() {
        var record = CaptureRecord(method: "GET", url: "https://example.test/p?q=first&q=second")
        record.sentMethod = "POST"; record.finalURL = "https://rewritten.test/a%2Fb?q=sent"
        record.originalStatus = 503; record.status = 200
        record.requestHeaders = [.init("X-ID", "first"), .init("x-id", "second")]
        record.receivedHeaders = [.init("X-ID", "upstream")]
        record.responseHeaders = [.init("X-ID", "returned")]
        let configured = column([[
            .init(field: .method, stage: .sentRequest, emptyBehavior: .customText, emptyText: "未发出"),
            .init(field: .url, stage: .sentRequest), .init(field: .path, stage: .sentRequest),
            .init(field: .header, name: "X-ID"), .init(field: .queryParameter, name: "q"),
            .init(field: .header, stage: .originalResponse, name: "X-ID"),
            .init(field: .header, stage: .returnedResponse, name: "X-ID"),
            .init(field: .status, stage: .originalResponse), .init(field: .status, stage: .returnedResponse)
        ]])
        var values = RequestLogRow(record: record).renderedLines(in: configured, allowLAN: false)[0].contents.map(\.text)
        #expect(values == ["未发出", "first\nsecond", "first\nsecond", "upstream", "returned", "503", "200"])
        record.hasSentRequestHeaders = true
        values = RequestLogRow(record: record).renderedLines(in: configured, allowLAN: false)[0].contents.map(\.text)
        #expect(Array(values.prefix(3)) == ["POST", record.finalURL, "/a%2Fb"])
        record.finalURLWasTruncated = true
        values = RequestLogRow(record: record).renderedLines(in: configured, allowLAN: false)[0].contents.map(\.text)
        #expect(!values.contains(record.finalURL))
        #expect(!values.contains("/a%2Fb"))
    }

    @Test func searchUsesFinalRenderedLinesIncludingFallbackAndExcludesUnconfiguredFields() {
        var record = CaptureRecord(method: "PATCH", url: "https://secret.test")
        record.requestHeaders = [.init("X-Visible", "alpha"), .init("X-Secret", "unconfigured")]
        let configured = column([[
            .init(field: .header, name: "X-Visible"),
            .init(field: .status, stage: .returnedResponse, emptyBehavior: .customText, emptyText: "等待响应")
        ]])
        var options = RequestLogDisplayOptions(); options.layoutColumns = [configured]
        let row = RequestLogRow(record: record, displayOptions: options)
        #expect(row.contains("ALPHA", displayOptions: options, allowLAN: false))
        #expect(row.contains("等待响应", displayOptions: options, allowLAN: false))
        #expect(row.contains("alpha 等待响应", displayOptions: options, allowLAN: false))
        for query in ["PATCH", "secret.test", "unconfigured", "—"] {
            #expect(!row.contains(query, displayOptions: options, allowLAN: false))
        }
        var filter = CaptureRecordFilter(); filter.search = "等待响应"
        #expect(filter.matches(record, displayOptions: options))
        options.layoutColumns[0].lines[0].contents[1].emptyBehavior = .hide
        #expect(!filter.matches(record, displayOptions: options))
    }

    @Test func explicitLayoutPersistsIdentitiesAlignmentEmptyPolicyAndPhysicalOrder() {
        let first = column([[.init(field: .ruleGroup)], [.init(field: .rule, horizontalAlignment: .right)]])
        let second = column([[.init(field: .status, stage: .returnedResponse, horizontalAlignment: .center,
                                   verticalAlignment: .top, emptyBehavior: .customText, emptyText: "尚无响应")]])
        var options = RequestLogDisplayOptions(); options.layoutColumns = [first, second]
        options.columnOrder = [second.id, "unknown", first.id, second.id]
        let restored = RequestLogDisplayOptions(preferences: options.preferences)
        #expect(restored.layoutColumns == [second, first])
        #expect(restored.orderedColumnIDs == [second.id, first.id])
        #expect(restored.title(forColumnID: first.id) == first.title)
        #expect(restored.isVisible(.rules, allowLAN: false))
        #expect(!restored.isVisible(.request, allowLAN: false))
        var reordered = restored; reordered.layoutColumns.swapAt(0, 1)
        #expect(reordered.columnOrder == [first.id, second.id])
    }

    @Test(arguments: RequestLogContentPresentation.allCases)
    func everyFieldPersistsItsOwnAppearance(presentation: RequestLogContentPresentation) throws {
        let contents = RequestLogContentField.allCases.map { field in
            RequestLogLayoutContent(field: field, stage: field.stages.first ?? .originalRequest,
                                    name: field.needsName ? "X-ID" : "",
                                    appearance: .init(presentation: presentation))
        }
        let configured = column([contents])
        let data = try JSONEncoder().encode(configured)
        #expect(try JSONDecoder().decode(RequestLogLayoutColumn.self, from: data) == configured)
        var options = RequestLogDisplayOptions(); options.layoutColumns = [configured]
        let restored = RequestLogDisplayOptions(preferences: options.preferences)
        #expect(restored.layoutColumns == [configured])
        #expect(restored.layoutColumns[0].lines[0].contents.map(\.field) == RequestLogContentField.allCases)
        #expect(restored.layoutColumns[0].lines[0].contents.allSatisfy { $0.appearance.presentation == presentation })
    }

    @Test func repeatedFieldsHaveIndependentAppearanceAndFieldChangesRetainIt() {
        var tag = RequestLogLayoutContent(field: .method, appearance: .init(presentation: .roundedRectangleTag))
        let plain = RequestLogLayoutContent(field: .method, appearance: .init(presentation: .plainText))
        let identity = tag.id
        tag.field = .header; tag.name = "X-Method"
        var options = RequestLogDisplayOptions(); options.layoutColumns = [column([[tag, plain]])]
        var restored = RequestLogDisplayOptions(preferences: options.preferences)
        var layout = restored.layoutColumns
        #expect(layout[0].lines[0].contents[0].id == identity)
        #expect(layout[0].lines[0].contents.map(\.appearance.presentation) == [.roundedRectangleTag, .plainText])
        layout[0].lines[0].contents[0].field = .method
        restored.layoutColumns = layout
        let changedBack = RequestLogDisplayOptions(preferences: restored.preferences).layoutColumns[0].lines[0].contents
        #expect(changedBack.map(\.field) == [.method, .method])
        #expect(changedBack[0].id == identity)
        #expect(changedBack.map(\.appearance.presentation) == [.roundedRectangleTag, .plainText])
    }

    @Test func layoutsSavedBeforeAppearanceKeepAllContentAndDefaultToAutomatic() throws {
        let methodID = UUID(), headerID = UUID(), lineID = UUID()
        let legacy: [String: Any] = [
            "id": "layout.legacy", "title": "已有列", "lines": [[
                "id": lineID.uuidString, "contents": [
                    ["id": methodID.uuidString, "field": "method", "stage": "sentRequest", "name": "",
                     "horizontalAlignment": "center", "verticalAlignment": "top",
                     "emptyBehavior": "customText", "emptyText": "尚未发出"],
                    ["id": headerID.uuidString, "field": "header", "stage": "returnedResponse", "name": "X-ID",
                     "horizontalAlignment": "right", "verticalAlignment": "bottom",
                     "emptyBehavior": "hide", "emptyText": ""]
                ]
            ]]
        ]
        let expected = RequestLogLayoutColumn(id: "layout.legacy", title: "已有列", lines: [
            .init(id: lineID, contents: [
                .init(id: methodID, field: .method, stage: .sentRequest, horizontalAlignment: .center,
                      verticalAlignment: .top, emptyBehavior: .customText, emptyText: "尚未发出"),
                .init(id: headerID, field: .header, stage: .returnedResponse, name: "X-ID",
                      horizontalAlignment: .right, verticalAlignment: .bottom)
            ])
        ])
        let data = try JSONSerialization.data(withJSONObject: legacy)
        #expect(try JSONDecoder().decode(RequestLogLayoutColumn.self, from: data) == expected)
        let restored = RequestLogDisplayOptions(preferences: ["layoutColumns": [legacy]])
        #expect(restored.layoutColumns == [expected])
        #expect(RequestLogDisplayOptions(preferences: restored.preferences).layoutColumns == [expected])
    }

    @Test func missingOrNullPresentationDefaultsToAutomatic() throws {
        for json in ["{}", "{\"presentation\":null}"] {
            let restored = try JSONDecoder().decode(RequestLogContentAppearance.self, from: Data(json.utf8))
            #expect(restored == .init())
        }
    }

    @Test func selectablePresentationStylesExcludeLegacyAutomaticWithoutRewritingIt() throws {
        #expect(RequestLogContentPresentation.selectableCases == [.plainText, .roundedRectangleTag, .capsule])
        #expect(RequestLogContentPresentation.selectableCases.map(\.title) == ["纯文字", "圆角标签", "胶囊"])
        let restored = try JSONDecoder().decode(RequestLogContentAppearance.self,
                                               from: Data(#"{"presentation":"automatic"}"#.utf8))
        #expect(restored.presentation == .automatic)
        #expect(restored.presentation.effectivePresentation == .plainText)
        #expect(try JSONDecoder().decode(RequestLogContentAppearance.self,
                                        from: JSONEncoder().encode(restored)) == restored)
    }

    @Test func capsuleAndNoTruncationPersistInLayoutJSONAndPreferences() throws {
        let appearance = RequestLogContentAppearance(presentation: .capsule, truncation: .none)
        let content = RequestLogLayoutContent(field: .header, name: "X-ID", appearance: appearance)
        let configured = column([[content]])
        let data = try JSONEncoder().encode(configured)
        #expect(try JSONDecoder().decode(RequestLogLayoutColumn.self, from: data) == configured)
        var options = RequestLogDisplayOptions(); options.layoutColumns = [configured]
        #expect(RequestLogDisplayOptions(preferences: options.preferences).layoutColumns == [configured])
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(appearance)) as? [String: Any])
        #expect(encoded["presentation"] as? String == "capsule")
        #expect(encoded["truncation"] as? String == "none")
        #expect(RequestLogTruncation.none.title == "不省略")
    }

    @Test func legacyPresentationAndTruncationRawValuesRemainCompatible() throws {
        for presentation in ["automatic", "plainText", "roundedRectangleTag"] {
            for truncation in ["automatic", "middle", "tail"] {
                let data = try JSONSerialization.data(withJSONObject: [
                    "presentation": presentation, "truncation": truncation
                ])
                let restored = try JSONDecoder().decode(RequestLogContentAppearance.self, from: data)
                #expect(restored.presentation.rawValue == presentation)
                #expect(restored.truncation.rawValue == truncation)
                #expect(restored.presentation.effectivePresentation == (presentation == "automatic" ? .plainText : restored.presentation))
            }
        }
    }

    @Test func typedAppearancePersistsAllOptionsAcrossFieldChangesAndLegacyPresentationGetsDefaults() throws {
        let appearance = RequestLogContentAppearance(
            presentation: .roundedRectangleTag, usesSemanticColors: false, font: .monospaced,
            weight: .semibold, truncation: .middle, emphasizesHost: true, showsStatusDescription: true,
            emphasizesErrors: false, timePrecision: .milliseconds, durationUnit: .seconds,
            durationPrecision: .hundredths, highlightsSlowRequests: true, slowThresholdMilliseconds: 2400,
            ruleSeparator: .arrow, repeatedValues: .multipleLines, showsValueCount: true)
        var content = RequestLogLayoutContent(field: .method, appearance: appearance)
        for field in RequestLogContentField.allCases {
            content.field = field; content.stage = field.stages.first ?? .originalRequest
            content.name = field.needsName ? "X-ID" : ""
            var options = RequestLogDisplayOptions(); options.layoutColumns = [column([[content]])]
            let restored = RequestLogDisplayOptions(preferences: options.preferences)
            #expect(restored.layoutColumns[0].lines[0].contents[0] == content)
        }
        let legacy = Data(#"{"presentation":"roundedRectangleTag"}"#.utf8)
        #expect(try JSONDecoder().decode(RequestLogContentAppearance.self, from: legacy)
            == .init(presentation: .roundedRectangleTag))
    }

    @Test func contentBackgroundColorsSurviveLayoutSavingAndPresentationChanges() throws {
        let color = RequestLogBackgroundColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 0.7)
        var content = RequestLogLayoutContent(field: .method,
            appearance: .init(presentation: .roundedRectangleTag, backgroundColor: color))
        content.appearance.presentation = .plainText
        content.field = .header
        content.name = "X-ID"
        var options = RequestLogDisplayOptions()
        options.layoutColumns = [column([[content, .init(field: .status)]])]
        let restored = try JSONDecoder().decode(RequestLogDisplayOptions.self, from: JSONEncoder().encode(options))
        let contents = restored.layoutColumns[0].lines[0].contents
        #expect(contents[0].appearance.backgroundColor == color)
        #expect(contents[0].appearance.presentation == .plainText)
        #expect(contents[1].appearance.backgroundColor == nil)
        content.appearance.presentation = .capsule
        #expect(content.appearance.backgroundColor == color)
        content.appearance.backgroundColor = nil
        let reset = try JSONDecoder().decode(RequestLogLayoutContent.self, from: JSONEncoder().encode(content))
        #expect(reset.appearance.backgroundColor == nil)
    }

    @Test func backgroundColorDecodingKeepsLegacyDefaultsAndBoundsImportedComponents() throws {
        let legacy = Data(#"{"presentation":"capsule"}"#.utf8)
        #expect(try JSONDecoder().decode(RequestLogContentAppearance.self, from: legacy).backgroundColor == nil)
        let imported = Data(#"{"backgroundColor":{"red":2,"green":-1,"blue":0.5}}"#.utf8)
        let appearance = try JSONDecoder().decode(RequestLogContentAppearance.self, from: imported)
        #expect(appearance.backgroundColor == RequestLogBackgroundColor(red: 1, green: 0, blue: 0.5, alpha: 1))
        let invalid = RequestLogBackgroundColor(red: .nan, green: .infinity, blue: -1, alpha: 2)
        #expect(invalid == .init(red: 0, green: 0, blue: 0, alpha: 1))
    }

    @Test func everyTypedAppearanceEnumValueSurvivesCodableRoundTrip() throws {
        var appearances: [RequestLogContentAppearance] = []
        appearances += RequestLogFont.allCases.map { .init(font: $0) }
        appearances += RequestLogFontWeight.allCases.map { .init(weight: $0) }
        appearances += RequestLogTruncation.allCases.map { .init(truncation: $0) }
        appearances += RequestLogTimePrecision.allCases.map { .init(timePrecision: $0) }
        appearances += RequestLogDurationUnit.allCases.map { .init(durationUnit: $0) }
        appearances += RequestLogDecimalPrecision.allCases.map { .init(durationPrecision: $0) }
        appearances += RequestLogRuleSeparator.allCases.map { .init(ruleSeparator: $0) }
        appearances += RequestLogRepeatedValues.allCases.map { .init(repeatedValues: $0) }
        let data = try JSONEncoder().encode(appearances)
        #expect(try JSONDecoder().decode([RequestLogContentAppearance].self, from: data) == appearances)
    }

    @Test func slowThresholdIsBoundedForUseWithoutRewritingSavedValue() throws {
        for (saved, effective) in [(Int.min, 1), (0, 1), (1000, 1000), (3_600_001, 3_600_000), (Int.max, 3_600_000)] {
            let appearance = RequestLogContentAppearance(highlightsSlowRequests: true, slowThresholdMilliseconds: saved)
            let restored = try JSONDecoder().decode(RequestLogContentAppearance.self, from: JSONEncoder().encode(appearance))
            #expect(restored.slowThresholdMilliseconds == saved)
            #expect(restored.effectiveSlowThresholdMilliseconds == effective)
        }
    }

    @Test func formattedTimeDurationAndStageSpecificStatusDescriptionsAreAlsoSearchable() throws {
        var record = CaptureRecord(method: "GET", url: "https://example.test")
        record.startedAt = try #require(Calendar.current.date(from: DateComponents(
            year: 2026, month: 9, day: 30, hour: 12, minute: 34, second: 56))).addingTimeInterval(0.123)
        record.duration = 1.234; record.originalStatus = 404; record.status = 200
        let configured = column([[
            .init(field: .time, appearance: .init(timePrecision: .milliseconds)),
            .init(field: .duration, appearance: .init(durationUnit: .seconds, durationPrecision: .hundredths)),
            .init(field: .status, stage: .originalResponse, appearance: .init(showsStatusDescription: true)),
            .init(field: .status, stage: .returnedResponse, appearance: .init(showsStatusDescription: true))
        ]])
        var options = RequestLogDisplayOptions(); options.layoutColumns = [configured]
        let row = RequestLogRow(record: record, displayOptions: options)
        #expect(row.startedAt == record.startedAt)
        #expect(row.durationSeconds == 1.234)
        #expect(row.renderedLines(in: configured, allowLAN: false)[0].contents.map(\.text)
            == ["12:34:56.123", "1.23 s", "404 Not Found", "200 OK"])
        for query in ["12:34:56.123", "1.23 s", "404 Not Found", "200 OK"] {
            var filter = CaptureRecordFilter(); filter.search = query
            #expect(filter.matches(record, displayOptions: options))
        }
        options.layoutColumns = [column([[
            .init(field: .time), .init(field: .duration), .init(field: .status, stage: .returnedResponse)
        ]])]
        #expect(!row.contains(".123", displayOptions: options, allowLAN: false))
        #expect(!row.contains("Not Found", displayOptions: options, allowLAN: false))
        #expect(!row.contains("200 OK", displayOptions: options, allowLAN: false))
    }

    @Test func durationUnitsAndDecimalPrecisionApplyWithoutChangingRawSeconds() {
        var record = CaptureRecord(method: "GET", url: "https://example.test"); record.duration = 1.234
        let row = RequestLogRow(record: record)
        let expected: [RequestLogDurationUnit: [String]] = [
            .automatic: ["1.2 s", "1 s", "1.2 s", "1.23 s"],
            .milliseconds: ["1234 ms", "1234 ms", "1234.0 ms", "1234.00 ms"],
            .seconds: ["1.2 s", "1 s", "1.2 s", "1.23 s"]
        ]
        for unit in RequestLogDurationUnit.allCases {
            let configured = column([RequestLogDecimalPrecision.allCases.map {
                .init(field: .duration, appearance: .init(durationUnit: unit, durationPrecision: $0))
            }])
            #expect(row.renderedLines(in: configured, allowLAN: false)[0].contents.map(\.text) == expected[unit])
            #expect(row.durationSeconds == 1.234)
        }
        record.duration = 0.125
        #expect(RequestLogRow(record: record).duration == "125 ms")
        record.duration = -1
        let negative = RequestLogRow(record: record)
        #expect(negative.durationSeconds == 0)
        #expect(negative.duration == "0 ms")
        #expect(record.duration == -1)
    }

    @Test func activeConnectionsKeepTheirSummaryAcrossNumericDurationChoices() {
        var record = CaptureRecord(method: "GET", url: "https://example.test")
        record.captureProtocol = .sse; record.connectionState = .open; record.duration = 12.345
        let configured = column([[.init(field: .duration, appearance: .init(
            durationUnit: .milliseconds, durationPrecision: .hundredths, highlightsSlowRequests: true))]])
        var options = RequestLogDisplayOptions(); options.layoutColumns = [configured]
        for archived in [false, true] {
            record.archivedAt = archived ? Date() : nil
            let row = RequestLogRow(record: record)
            #expect(row.durationSeconds == 12.345)
            #expect(row.renderedLines(in: configured, allowLAN: false)[0].contents[0].text == record.connectionSummary)
            #expect(row.contains(record.connectionSummary, displayOptions: options, allowLAN: false))
            #expect(!row.contains("12345.00 ms", displayOptions: options, allowLAN: false))
        }
    }

    @Test(arguments: RequestLogRuleSeparator.allCases)
    func ruleSeparatorsControlDisplayedLinesAndSearch(separator: RequestLogRuleSeparator) {
        var record = CaptureRecord(method: "GET", url: "https://example.test")
        record.matchedWorkflowID = UUID(); record.project = "商城"; record.workflow = "追踪"
        let configured = column([[.init(field: .rules, appearance: .init(ruleSeparator: separator))]])
        var options = RequestLogDisplayOptions(); options.layoutColumns = [configured]
        let row = RequestLogRow(record: record)
        let line = row.renderedLines(in: configured, allowLAN: false)[0]
        let expected: [RequestLogRuleSeparator: String] = [
            .automatic: "商城 · 追踪", .dot: "商城 · 追踪", .slash: "商城 / 追踪",
            .arrow: "商城 → 追踪", .newLine: "商城\n追踪"
        ]
        #expect(line.contents[0].displayText == expected[separator])
        #expect(line.displayLineCount == (separator == .newLine ? 2 : 1))
        #expect(row.contains(expected[separator]!, displayOptions: options, allowLAN: false))
    }

    @Test func repeatedValuesKeepFullTextAccurateCountsAndSearchInSingleAndMultipleLines() {
        var record = CaptureRecord(method: "GET", url: "https://example.test/?q=first%0Ainside&q=second")
        record.requestHeaders = [.init("X-ID", "alpha\ninside"), .init("x-id", "beta")]
        for presentation in RequestLogRepeatedValues.allCases {
            let appearance = RequestLogContentAppearance(repeatedValues: presentation, showsValueCount: true)
            let configured = column([[
                .init(field: .header, name: "X-ID", appearance: appearance),
                .init(field: .queryParameter, name: "q", appearance: appearance),
                .init(field: .header, name: "X-Missing", emptyBehavior: .customText,
                      emptyText: "无值", appearance: appearance)
            ]])
            var options = RequestLogDisplayOptions(); options.layoutColumns = [configured]
            let row = RequestLogRow(record: record)
            let line = row.renderedLines(in: configured, allowLAN: false)[0]
            #expect(line.contents.map(\.text) == ["alpha\ninside\nbeta", "first\ninside\nsecond", "无值"])
            #expect(line.contents.map(\.valueCount) == [2, 2, 0])
            let expected = presentation == .multipleLines ? "alpha\ninside\nbeta (2项)" : "alpha · inside · beta (2项)"
            #expect(line.contents[0].displayText == expected)
            #expect(line.contents[2].displayText == "无值")
            #expect(line.displayLineCount == (presentation == .multipleLines ? 3 : 1))
            #expect(row.contains(expected, displayOptions: options, allowLAN: false))
            #expect(row.contains("alpha\ninside\nbeta", displayOptions: options, allowLAN: false))
            #expect(row.contains("first\ninside\nsecond", displayOptions: options, allowLAN: false))
            #expect(row.contains("(2项)", displayOptions: options, allowLAN: false))
        }
    }

    @Test func repeatedValueCountsFollowStagesAndDoNotInferTruncatedOrInvalidQueryValues() {
        var record = CaptureRecord(method: "GET", url: "https://example.test/?q=&q=second")
        record.finalURL = "https://example.test/?q=sent"; record.hasSentRequestHeaders = true
        record.responseHeaders = [.init("X-ID", "returned"), .init("X-ID", "")]
        let appearance = RequestLogContentAppearance(showsValueCount: true)
        let configured = column([[
            .init(field: .queryParameter, name: "q", appearance: appearance),
            .init(field: .queryParameter, stage: .sentRequest, name: "q",
                  emptyBehavior: .customText, emptyText: "无值", appearance: appearance),
            .init(field: .header, stage: .returnedResponse, name: "X-ID", appearance: appearance)
        ]])
        let first = RequestLogRow(record: record).renderedLines(in: configured, allowLAN: false)[0].contents
        #expect(first.map(\.valueCount) == [2, 1, 2])
        #expect(first[0].text == "\nsecond")
        record.finalURLWasTruncated = true
        let truncated = RequestLogRow(record: record).renderedLines(in: configured, allowLAN: false)[0].contents
        #expect(truncated[1].valueCount == 0)
        #expect(truncated[1].displayText == "无值")
        record.finalURLWasTruncated = false; record.finalURL = "/relative?q=unknown"
        let invalid = RequestLogRow(record: record).renderedLines(in: configured, allowLAN: false)[0].contents
        #expect(invalid[1].valueCount == 0)
        #expect(invalid[1].displayText == "无值")
    }

    @Test func explicitEmptyLayoutStaysEmptyAfterSavingAndLegacyChanges() {
        var options = RequestLogDisplayOptions(); options.layoutColumns = []
        let restored = RequestLogDisplayOptions(preferences: options.preferences)
        #expect(restored.explicitLayout != nil)
        #expect(restored.layoutColumns.isEmpty)
        #expect(restored.visibleColumnIDs(allowLAN: true).isEmpty)
        #expect(!RequestLogRow(record: .init(method: "GET", url: "https://example.test"))
            .contains("GET", displayOptions: restored, allowLAN: true))
    }

    @Test func legacyMigrationKeepsOrderStagesMergedFieldsAndStableLayoutIdentities() {
        var legacy = RequestLogDisplayOptions()
        let host = RequestLogExtraColumn(field: .host, stage: .sentRequest, title: "发出的主机", mergedInto: "request")
        let header = RequestLogExtraColumn(name: "X-ID", mergedInto: host.identifier)
        let hidden = RequestLogExtraColumn(name: "X-Hidden", isEnabled: false)
        legacy.extraColumns = [host, header, hidden]
        legacy.columnOrder = ["rules", header.identifier, "request", "duration", host.identifier, "time", "status", "device"]
        let projected = legacy.layoutColumns
        #expect(projected == legacy.layoutColumns)
        #expect(projected.map(\.id) == ["rules", "request", "duration", "time", "device"])
        #expect(projected[0].lines.map { $0.contents.map(\.field) } == [[.ruleGroup], [.rule]])
        let request = projected[1]
        #expect(request.lines[0].contents.map(\.field) == [.status, .method, .url])
        #expect(request.lines[1].contents.map(\.field) == [.detail, .header, .host])
        #expect(request.lines[1].contents[1].id == header.id)
        #expect(request.lines[1].contents[2].stage == .sentRequest)
        #expect(request.lines[1].contents.allSatisfy { $0.emptyBehavior == .hide })
        #expect(projected[2].lines[0].contents[0].horizontalAlignment == .right)
        #expect(projected[3].lines[0].contents[0].horizontalAlignment == .left)
        #expect(projected[4].lines[0].contents[0].horizontalAlignment == .center)
        var explicit = legacy; explicit.layoutColumns = projected
        #expect(RequestLogDisplayOptions(preferences: explicit.preferences).layoutColumns == projected)
    }

    @Test func invalidContentsStayHiddenAndSavedDuplicateColumnsAreDiscarded() {
        #expect(RequestLogLayoutContent(field: .header).displayTitle == "Header")
        #expect(RequestLogLayoutContent(field: .queryParameter, name: "  ").displayTitle == "查询参数")
        #expect(RequestLogLayoutContent(field: .header, name: " X-ID ").displayTitle == "X-ID")
        let configured = column([[
            .init(field: .header, name: "bad name", emptyBehavior: .customText, emptyText: "invalid"),
            .init(field: .status, stage: .originalRequest, emptyBehavior: .customText, emptyText: "invalid")
        ]])
        var options = RequestLogDisplayOptions(); options.layoutColumns = [configured]
        #expect(options.visibleColumnIDs(allowLAN: true).isEmpty)
        #expect(RequestLogRow(record: .init(method: "GET", url: "https://example.test"))
            .renderedLines(in: configured, allowLAN: true).isEmpty)
        var preferences = options.preferences
        let saved = preferences["layoutColumns"] as! [[String: Any]]
        preferences["layoutColumns"] = saved + saved + [["id": "broken"]]
        #expect(RequestLogDisplayOptions(preferences: preferences).layoutColumns == [configured])
    }
}
