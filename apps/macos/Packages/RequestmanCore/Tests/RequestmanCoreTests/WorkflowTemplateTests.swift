import Foundation
import Testing
@testable import RequestmanCore

struct WorkflowTemplateTests {
    @Test func catalogAndFormats() throws {
        let request = HTTPMessageDraft(method: "POST", url: "https://example.test:8443/a%20b?q=1")
        let context = WorkflowTemplateContext(id: UUID(), date: Date(timeIntervalSince1970: 1_700_000_000.125), request: request)
        func resolve(_ key: String) throws -> String {
            try WorkflowEngine.resolve("{{\(key)}}", environment: [:], context: context, responseStatus: 201)
        }
        for item in WorkflowTemplateContext.variables {
            #expect(try !resolve(item.name).isEmpty)
            #expect(try resolve(item.name) == resolve(item.name))
        }
        #expect(try resolve("$timestamp") == "1700000000")
        #expect(try resolve("$timestampMs") == "1700000000125")
        #expect(try resolve("$isoDateTime") == "2023-11-14T22:13:20.125Z")
        #expect(try resolve("$date") == "2023-11-14")
        #expect(try resolve("$time") == "22:13:20")
        #expect(try resolve("$request.method") == "POST")
        #expect(try resolve("$request.url") == request.url)
        #expect(try resolve("$request.host") == "example.test")
        #expect(try resolve("$request.path") == "/a%20b")
        #expect(try resolve("$response.status") == "201")
        #expect(try (0...999_999).contains(Int(resolve("$randomInt"))!))
        #expect(try (0..<1).contains(Double(resolve("$randomFloat"))!))
        #expect(try ["true", "false"].contains(resolve("$randomBoolean")))
        #expect(try resolve("$randomString").range(of: "^[A-Za-z0-9]{16}$", options: .regularExpression) != nil)
        #expect(try resolve("$randomHex").range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil)
        let another = WorkflowTemplateContext(id: UUID(), date: Date(), request: request)
        #expect(try resolve("$randomHex") != WorkflowEngine.resolve("{{$randomHex}}", environment: [:], context: another))
        #expect(throws: WorkflowError.self) { try WorkflowEngine.resolve("{{$response.status}}", environment: [:], context: context) }
    }

    @Test func originalRequestAndStableValuesAcrossStagesAndMock() throws {
        let id = UUID(), date = Date()
        var draft = HTTPMessageDraft(method: "GET", url: "https://original.test/original?q=1")
        let context = WorkflowTemplateContext(id: id, date: date, request: draft)
        var rewrite = ModificationStep(kind: .rewriteURL); rewrite.value = "https://modified.test/changed"
        var method = ModificationStep(kind: .setMethod); method.value = "POST"
        var mock = ModificationStep(kind: .mock); mock.status = 202
        mock.value = "{{$request.method}} {{$request.url}} {{$randomString}} {{$randomString}}"
        _ = try WorkflowEngine.apply([rewrite, method, mock], response: false, to: &draft, environment: [:], id: id, date: date, templateContext: context)
        let random = try WorkflowEngine.resolve("{{$randomString}}", environment: [:], context: context)
        #expect(draft.replacementBody == "GET https://original.test/original?q=1 \(random) \(random)")
        var status = ModificationStep(kind: .setStatus); status.status = 203
        var header = ModificationStep(kind: .setHeader)
        header.headerEntries = [HeaderEntry(name: "X-Context", value: "{{$response.status}} {{$request.host}} {{$randomString}}")]
        _ = try WorkflowEngine.apply([status, header], response: true, to: &draft, environment: [:], id: id, date: date, templateContext: context)
        #expect(draft.headers.last?.value == "202 original.test \(random)")
        #expect(draft.status == 203)
    }
}
