import Foundation
import RequestmanCore

func runPayloadPresentationChecks() throws {
    precondition(RequestDetailTab.allCases.map(\.title) == ["请求头", "请求体", "响应头", "响应体"])
    precondition(InspectionVersion.allCases.map(\.title) == ["原始", "最终", "差异"])
    precondition(RequestDetailTab.requestHeaders.isRequest && !RequestDetailTab.requestHeaders.isBody)
    precondition(RequestDetailTab.responseBody.isBody && !RequestDetailTab.responseBody.isRequest)

    var noUpstream = CaptureRecord(method: "POST", url: "https://example.test/items")
    noUpstream.requestHeaders = [HTTPField("X-Original", "yes")]
    noUpstream.sentHeaders = [HTTPField("X-Original", "prepared but unsent")]
    noUpstream.requestBody = payloadSnapshot("{}")
    noUpstream.sentBody = .unavailable("本地响应，请求未发送至上游")
    let originalHeaders = RequestPayloadPresentation.make(record: noUpstream, tab: .requestHeaders, version: .original)
    precondition(originalHeaders.nodes.first?.copyValue == "yes" && !originalHeaders.canCompare)
    precondition(originalHeaders.nodes.allSatisfy { $0.change == .unchanged })
    for version in [InspectionVersion.final, .difference] {
        let unsent = RequestPayloadPresentation.make(record: noUpstream, tab: .requestHeaders, version: version)
        precondition(unsent.nodes.isEmpty && unsent.emptyDescription?.contains("未发送") == true)
        precondition(!unsent.canCompare, "Prepared but unsent headers cannot count as transmitted content")
    }

    var mock = noUpstream
    mock.outcome = .mocked
    mock.status = 201
    mock.responseHeaders = [HTTPField("Content-Type", "application/json")]
    mock.receivedBody = .unavailable("本地响应，没有服务器原始响应")
    mock.responseBody = payloadSnapshot(#"{"created":true}"#)
    let mockOriginalHeaders = RequestPayloadPresentation.make(record: mock, tab: .responseHeaders, version: .original)
    precondition(mockOriginalHeaders.emptyDescription?.contains("没有服务器原始响应") == true)
    let mockFinalHeaders = RequestPayloadPresentation.make(record: mock, tab: .responseHeaders, version: .final)
    precondition(mockFinalHeaders.nodes.count == 1 && !mockFinalHeaders.canCompare)
    precondition(mockFinalHeaders.nodes[0].change == .unchanged)
    let mockOriginalBody = RequestPayloadPresentation.make(record: mock, tab: .responseBody, version: .original)
    precondition(mockOriginalBody.emptyTitle == "无可用 Body")
    let mockDifference = RequestPayloadPresentation.make(record: mock, tab: .responseBody, version: .difference)
    precondition(mockDifference.isJSON && !mockDifference.canCompare)
    precondition(mockDifference.nodes[0].change == .unchanged)

    var record = CaptureRecord(method: "GET", url: "https://example.test/data")
    record.originalStatus = 404
    record.status = 200
    record.requestBody = payloadSnapshot("")
    record.sentBody = payloadSnapshot("")
    record.receivedBody = payloadSnapshot(#"{"status":"missing"}"#)
    record.responseBody = payloadSnapshot(#"{"status":"found"}"#)
    record.requestHeaders = [HTTPField("X-Remove", "old")]
    record.receivedHeaders = [HTTPField("X-Status", "missing")]
    record.responseHeaders = [HTTPField("X-Status", "found")]

    let emptyRequest = RequestPayloadPresentation.make(record: record, tab: .requestBody, version: .final)
    precondition(emptyRequest.emptyTitle == "无 Body" && emptyRequest.canCompare)
    precondition(emptyRequest.source.isEmpty && !emptyRequest.isJSON)
    let removedHeaders = RequestPayloadPresentation.make(record: record, tab: .requestHeaders, version: .difference)
    precondition(removedHeaders.canCompare && removedHeaders.nodes[0].change == .removed)
    let emptyHeaders = RequestPayloadPresentation.make(record: record, tab: .requestHeaders, version: .final)
    precondition(emptyHeaders.emptyTitle == "无 Header" && emptyHeaders.canCompare)

    let originalResponse = RequestPayloadPresentation.make(record: record, tab: .responseBody, version: .original)
    let finalResponse = RequestPayloadPresentation.make(record: record, tab: .responseBody, version: .final)
    let responseDifference = RequestPayloadPresentation.make(record: record, tab: .responseBody, version: .difference)
    precondition(originalResponse.source.contains("missing") && !originalResponse.source.contains("found"))
    precondition(finalResponse.source.contains("found") && !finalResponse.source.contains("missing"))
    precondition(responseDifference.source.contains("missing") && responseDifference.source.contains("found"))
    precondition(responseDifference.nodes[0].children[0].originalValue == #""missing""#)
    precondition(originalResponse.canCompare && finalResponse.canCompare)
    precondition(record.originalStatus == 404 && record.status == 200, "Version selection cannot mutate recorded statuses")
    let responseOldHeaders = RequestPayloadPresentation.make(record: record, tab: .responseHeaders, version: .original)
    let responseNewHeaders = RequestPayloadPresentation.make(record: record, tab: .responseHeaders, version: .final)
    precondition(responseOldHeaders.nodes[0].copyValue == "missing" && responseNewHeaders.nodes[0].copyValue == "found")

    var incomplete = record
    incomplete.responseBody = payloadSnapshot(#"{"valid":"JSON"}"#, isComplete: false)
    let partialJSON = RequestPayloadPresentation.make(record: incomplete, tab: .responseBody, version: .difference)
    precondition(!partialJSON.isJSON && partialJSON.nodes.isEmpty && !partialJSON.canCompare)
    precondition(partialJSON.source == #"{"valid":"JSON"}"# && partialJSON.notice?.contains("传输未完成") == true)

    var large = record
    let largeText = "{\"payload\":\"" + String(repeating: "x", count: 1_048_576) + "\"}"
    large.responseBody = payloadSnapshot(largeText)
    let largeView = RequestPayloadPresentation.make(record: large, tab: .responseBody, version: .final)
    precondition(largeView.isJSON && largeView.source == largeText)
    precondition(largeView.nodes[0].children[0].copyValue.utf8.count == 1_048_578)

    var changedFormat = record
    changedFormat.receivedBody = payloadSnapshot("previous plain text", contentType: "text/plain")
    changedFormat.responseBody = payloadSnapshot(#"{"next":"JSON"}"#)
    let formatFinal = RequestPayloadPresentation.make(record: changedFormat, tab: .responseBody, version: .final)
    precondition(formatFinal.isJSON && !formatFinal.canCompare, "A valid final tree must not expose a fake field comparison")
    let formatDifference = RequestPayloadPresentation.make(record: changedFormat, tab: .responseBody, version: .difference)
    precondition(!formatDifference.isJSON && formatDifference.nodes.isEmpty && formatDifference.canCompare)
    precondition(formatDifference.source.contains("previous plain text") && formatDifference.source.contains("next"))
    precondition(formatDifference.copyText == #"{"next":"JSON"}"#, "Copy current body should not include diff labels")

    var cleared = record
    cleared.responseBody = payloadSnapshot("")
    let clearedDifference = RequestPayloadPresentation.make(record: cleared, tab: .responseBody, version: .difference)
    precondition(clearedDifference.emptyTitle == nil && clearedDifference.canCompare && !clearedDifference.isJSON)
    precondition(clearedDifference.source.contains("missing") && clearedDifference.source.contains("最终\n（无 Body）"))
    var introduced = record
    introduced.receivedBody = payloadSnapshot("")
    let introducedDifference = RequestPayloadPresentation.make(record: introduced, tab: .responseBody, version: .difference)
    precondition(!introducedDifference.isJSON && introducedDifference.canCompare)
    precondition(introducedDifference.source.contains("原始\n（无 Body）") && introducedDifference.source.contains("found"))

    let emptyGzip = Data(base64Encoded: "H4sIAAAAAAAC/wMAAAAAAAAAAAA=")!
    var decodedEmpty = record
    decodedEmpty.responseBody = payloadSnapshot(bytes: emptyGzip, encoding: "gzip")
    let decodedEmptyView = RequestPayloadPresentation.make(record: decodedEmpty, tab: .responseBody, version: .final)
    precondition(decodedEmptyView.emptyTitle == "无 Body" && decodedEmptyView.canCompare)
    var invalidGzip = record
    invalidGzip.responseBody = payloadSnapshot(bytes: Data(), encoding: "gzip")
    let invalidEmptyView = RequestPayloadPresentation.make(record: invalidGzip, tab: .responseBody, version: .final)
    precondition(invalidEmptyView.emptyTitle == "没有可用的内容预览" && !invalidEmptyView.canCompare)

    var unavailable = record
    unavailable.responseBody = .notCollected
    let uncollected = RequestPayloadPresentation.make(record: unavailable, tab: .responseBody, version: .final)
    precondition(uncollected.emptyTitle == "未采集 Body" && !uncollected.canCompare)
    unavailable.outcome = .tunnel
    let tunnel = RequestPayloadPresentation.make(record: unavailable, tab: .requestHeaders, version: .original)
    precondition(tunnel.emptyTitle == "加密隧道" && tunnel.nodes.isEmpty)
    print("Payload presentation checks passed: message presence, version selection, empty/partial bodies, format changes and source comparisons")
}

private func payloadSnapshot(
    _ text: String, contentType: String = "application/json", isComplete: Bool = true
) -> CaptureBodySnapshot {
    payloadSnapshot(bytes: Data(text.utf8), contentType: contentType, isComplete: isComplete)
}

private func payloadSnapshot(
    bytes: Data, contentType: String = "application/json", encoding: String? = nil,
    isComplete: Bool = true
) -> CaptureBodySnapshot {
    var headers = [HTTPField("Content-Type", contentType)]
    if let encoding { headers.append(HTTPField("Content-Encoding", encoding)) }
    let collector = CaptureBodyCollector(headers: headers)
    collector.append(bytes)
    return collector.snapshot(isComplete: isComplete)
}
