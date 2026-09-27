import Foundation
import Testing
@testable import RequestmanCore

struct CapturedMockWorkflowTests {
    private func snapshot(_ data: Data, headers: [HTTPField] = [], complete: Bool = true) -> CaptureBodySnapshot {
        let collector = CaptureBodyCollector(headers: headers)
        collector.append(data)
        return collector.snapshot(isComplete: complete)
    }
    private func record() -> CaptureRecord {
        var record = CaptureRecord(method: "POST", url: "https://example.test/api?q=a%2Bb&q=second&flag")
        record.status = 201
        record.originalStatus = 500
        record.finalURL = "https://different.test/changed"
        record.requestHeaders = [HTTPField("Content-Type", "application/json"), HTTPField("X-Value", "{{$env.missing}}"),
                                 HTTPField("Host", "example.test"), HTTPField("Content-Length", "999")]
        record.responseHeaders = [HTTPField("Content-Type", "application/json"), HTTPField("Set-Cookie", "a=1"),
                                  HTTPField("Set-Cookie", "b=2"), HTTPField("Content-Length", "999"),
                                  HTTPField("Connection", "close, X-Hop"), HTTPField("X-Hop", "discard")]
        record.requestBody = snapshot(Data(#"{"input":"{{unchanged}}"}"#.utf8))
        record.responseBody = snapshot(Data(#"{"output":"{{$env.missing}}"}"#.utf8))
        record.receivedBody = snapshot(Data("wrong origin response".utf8))
        return record
    }
    private func execute(_ workflow: RequestWorkflow, record: CaptureRecord) throws -> HTTPMessageDraft {
        var draft = HTTPMessageDraft(method: record.method, url: record.url, headers: record.requestHeaders)
        _ = try WorkflowEngine.apply(workflow.requestSteps, response: false, to: &draft, environment: [:], id: UUID(), date: Date())
        #expect(!draft.isMock)
        return draft
    }
    @Test func decomposesOnlyOriginalRequestWithoutExpandingTemplates() throws {
        let record = record()
        let workflow = try CapturedMockWorkflow.make(from: record)
        #expect(workflow.matches(method: record.method, url: record.url))
        #expect(!workflow.matches(method: "GET", url: record.url))
        #expect(!workflow.matches(method: record.method, url: record.finalURL))
        #expect(workflow.requestSteps.map(\.kind) == [.setMethod, .rewriteURL, .replaceBody, .setHeader])
        #expect(workflow.requestSteps[1].value == record.url)
        #expect(Data(workflow.requestSteps[2].value.utf8) == record.requestBody.data)
        let draft = try execute(workflow, record: record)
        #expect(draft.replacementBytes == record.requestBody.data)
        #expect(workflow.responseSteps.map(\.kind) == [.setStatus, .replaceBody, .setHeader])
        #expect(workflow.requestSteps.last!.headerEntries.allSatisfy { $0.operation == .modify })
        #expect(draft.headers.filter { !WorkflowEngine.managedHeaders.contains($0.name.lowercased()) } == [HTTPField("Content-Type", "application/json"), HTTPField("X-Value", "{{$env.missing}}")])
        #expect(try JSONDecoder().decode(RequestWorkflow.self, from: JSONEncoder().encode(workflow)) == workflow)
        #expect(try CapturedMockWorkflow.make(from: record).id != workflow.id)
    }
    @Test func compressedAndBinaryRequestBytesRemainLossless() throws {
        var record = record()
        let bytes = Data([0, 255, 0x1f, 0x8b, 10, 13])
        record.requestHeaders = [HTTPField("Content-Encoding", "br"), HTTPField("Content-Type", "application/octet-stream")]
        record.requestBody = snapshot(bytes, headers: record.requestHeaders)
        let workflow = try CapturedMockWorkflow.make(from: record, decodeBody: { _ in throw WorkflowError.invalid("unsupported") })
        #expect(workflow.requestSteps[2].bodyEncoding == .base64)
        let draft = try execute(workflow, record: record)
        #expect(draft.replacementBytes == bytes)
        #expect(Set(draft.headers.map(\.name)) == Set(record.requestHeaders.map(\.name)))
        #expect(draft.headers.first { $0.name == "Content-Encoding" }?.value == "br")
    }
    @Test func decodedRequestTextDropsEncodingAndEmptyBodyStaysEmpty() throws {
        var record = record()
        record.requestHeaders = [HTTPField("Content-Encoding", "gzip"), HTTPField("ETag", "old"), HTTPField("Content-Type", "text/plain")]
        record.requestBody = snapshot(Data([1, 2, 3]), headers: record.requestHeaders)
        let workflow = try CapturedMockWorkflow.make(from: record, decodeBody: { _ in Data("hello".utf8) })
        let result = try execute(workflow, record: record)
        #expect(result.replacementBody == "hello")
        #expect(result.headers == [HTTPField("Content-Type", "text/plain")])
        record.requestHeaders = []; record.requestBody = snapshot(Data())
        let empty = try execute(CapturedMockWorkflow.make(from: record), record: record)
        #expect(empty.headers.isEmpty && empty.replacementBytes == Data())
    }
    @Test func headersUseModifyAndKeepCapturedValues() throws {
        var record = record()
        record.requestHeaders = [HTTPField("X-Value", "first"), HTTPField("x-value", "second"), HTTPField("X-Another", "last")]
        let workflow = try CapturedMockWorkflow.make(from: record)
        let entries = try #require(workflow.requestSteps.last?.headerEntries)
        #expect(entries.map(\.operation) == [.modify, .modify, .modify])
        #expect(entries.map(\.value) == ["first", "second", "last"])
        #expect(try execute(workflow, record: record).headers == [HTTPField("X-Value", "second"), HTTPField("x-value", "second"), HTTPField("X-Another", "last")])
    }
    @Test func onlyOriginalRequestCompletenessIsRequired() throws {
        var good = record()
        good.status = nil; good.originalStatus = nil; good.outcome = .failed; good.error = "Upstream failed"
        good.responseBody = .notCollected; good.responseHeadersInfo.isTruncated = true
        #expect(CapturedMockWorkflow.unavailableReason(for: good) == nil)
        #expect(try CapturedMockWorkflow.make(from: good).responseSteps.isEmpty)
        var cases: [CaptureRecord] = []
        var item = good; item.outcome = .tunnel; cases.append(item)
        item = good; item.requestBody = .notCollected; cases.append(item)
        item = good; item.requestBody = snapshot(Data([1]), complete: false); cases.append(item)
        item = good; item.requestHeadersInfo.isTruncated = true; cases.append(item)
        item = good; item.urlWasTruncated = true; cases.append(item)
        for record in cases {
            #expect(CapturedMockWorkflow.unavailableReason(for: record) != nil)
            #expect(throws: WorkflowError.self) { try CapturedMockWorkflow.make(from: record) }
        }
    }
    @Test func responseStepsUseOriginSnapshotInsteadOfModifiedResponse() throws {
        var record = record()
        record.receivedHeaders = [HTTPField("Content-Type", "text/plain"), HTTPField("Set-Cookie", "first=1"),
                                  HTTPField("Set-Cookie", "second=2"), HTTPField("X-Literal", "{{$env.missing}}"),
                                  HTTPField("Content-Length", "999")]
        record.receivedBody = snapshot(Data("original {{$env.missing}}".utf8), headers: record.receivedHeaders)
        let workflow = try CapturedMockWorkflow.make(from: record)
        #expect(workflow.responseSteps.map(\.kind) == [.setStatus, .replaceBody, .setHeader])
        #expect(workflow.responseSteps[0].status == 500)
        #expect(workflow.responseSteps[1].value == "original {{$env.missing}}")
        let entries = workflow.responseSteps[2].headerEntries
        #expect(entries.map(\.operation) == [.modify, .modify, .modify, .modify])
        #expect(entries.map(\.value) == ["text/plain", "first=1", "second=2", "{{$env.missing}}"])
        var response = HTTPMessageDraft(method: record.method, url: record.url, status: 202,
                                        headers: [HTTPField("Content-Type", "application/json"), HTTPField("Set-Cookie", "old=1"), HTTPField("Set-Cookie", "old=2"), HTTPField("X-Literal", "old")])
        _ = try WorkflowEngine.apply(workflow.responseSteps, response: true, to: &response, environment: [:], id: UUID(), date: Date())
        #expect(response.status == 500 && response.replacementBytes == record.receivedBody.data)
        #expect(response.headers == [HTTPField("Content-Type", "text/plain"), HTTPField("Set-Cookie", "second=2"), HTTPField("Set-Cookie", "second=2"), HTTPField("X-Literal", "{{$env.missing}}")])
        #expect(try JSONDecoder().decode(RequestWorkflow.self, from: JSONEncoder().encode(workflow)) == workflow)
    }
    @Test func incompleteOriginResponseDoesNotInventResponseSteps() throws {
        var record = record()
        record.receivedBody = .unavailable("本地响应，没有上游响应")
        #expect(try CapturedMockWorkflow.make(from: record).responseSteps.isEmpty)
        record.receivedBody = snapshot(Data())
        record.receivedHeadersInfo.isTruncated = true
        #expect(try CapturedMockWorkflow.make(from: record).responseSteps.isEmpty)
        record.receivedHeadersInfo.isTruncated = false
        record.originalStatus = 204
        let workflow = try CapturedMockWorkflow.make(from: record)
        #expect(workflow.responseSteps[0].status == 204 && workflow.responseSteps[1].value.isEmpty)
    }

    @Test func legacyStepsStillResolveAndInvalidBase64Fails() throws {
        var draft = HTTPMessageDraft(method: "GET", url: "http://localhost/")
        var step = ModificationStep(kind: .replaceBody); step.value = "{{$env.name}}"
        _ = try WorkflowEngine.apply([step], response: true, to: &draft, environment: ["name": "resolved"], id: UUID(), date: Date())
        #expect(draft.replacementBody == "resolved")
        step.bodyEncoding = .base64; step.literalValues = true
        #expect(throws: WorkflowError.self) {
            try WorkflowEngine.apply([step], response: true, to: &draft, environment: [:], id: UUID(), date: Date())
        }
    }
}
