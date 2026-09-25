import Foundation
import Testing
@testable import RequestmanCore

struct WorkflowEngineTests {
    @Test func orderedMatchingAndEnvironmentSnapshot() throws {
        var doc = WorkspaceDocument()
        var env = WorkspaceEnvironment(name: "dev")
        env.variables = [NamedValue(name: "token", value: "old")]
        doc.environments = [env]; doc.selectedEnvironmentID = env.id
        var first = RequestWorkflow(name: "first"); first.urlPrefix = "http://localhost/api"; first.method = "POST"
        var second = first; second.name = "second"; second.id = UUID()
        var project = WorkflowProject(); project.workflows = [first, second]; doc.projects = [project]
        let match = try #require(WorkflowEngine.match(doc, method: "POST", url: "http://localhost/api/test"))
        doc.environments[0].variables[0].value = "new"
        #expect(match.workflow.name == "first")
        #expect(match.environment?.values["token"] == "old")
        #expect(WorkflowEngine.match(doc, method: "GET", url: "http://localhost/api") == nil)
        doc.projects[0].workflows[0].urlPrefix = ""
        #expect(WorkflowEngine.match(doc, method: "POST", url: "http://localhost/api")?.workflow.name == "second")
    }
    @Test func dynamicValuesAreSinglePassAndMissingValuesFail() throws {
        let id = UUID(), date = Date(timeIntervalSince1970: 123)
        let value = try WorkflowEngine.resolve("{{env.key}}/{{$uuid}}/{{$timestamp}}", environment: ["key": "{{env.secret}}"], id: id, date: date)
        #expect(value == "{{env.secret}}/\(id)/123")
        #expect(throws: WorkflowError.self) { try WorkflowEngine.resolve("{{env.missing}}", environment: [:], id: id, date: date) }
    }
    @Test func invalidHeadersAndFramingAreRejected() {
        for (name, value) in [("Bad Name", "value"), ("X-Key", "value\r\nInjected: yes"), ("Content-Length", "99")] {
            var step = ModificationStep(kind: .setHeader); step.name = name; step.value = value
            var draft = HTTPMessageDraft(method: "GET", url: "http://localhost/")
            #expect(throws: WorkflowError.self) { try WorkflowEngine.apply([step], response: false, to: &draft, environment: [:], id: UUID(), date: Date()) }
        }
    }
    @Test func mockTerminatesRequestLaneAndResponseCanOverride() throws {
        var mock = ModificationStep(kind: .mock); mock.value = "hello"
        var rewrite = ModificationStep(kind: .rewriteURL); rewrite.value = "invalid"
        var status = ModificationStep(kind: .setStatus); status.status = 201
        var draft = HTTPMessageDraft(method: "GET", url: "http://localhost/")
        let trace = try WorkflowEngine.apply([mock, rewrite], response: false, to: &draft, environment: [:], id: UUID(), date: Date())
        #expect(trace.count == 1); #expect(draft.isMock)
        _ = try WorkflowEngine.apply([status], response: true, to: &draft, environment: [:], id: UUID(), date: Date())
        #expect(draft.status == 201); #expect(draft.replacementBody == "hello")
    }
    @Test func historyIsBoundedPausedAndRedacted() {
        let buffer = CaptureRecordBuffer(capacity: 2)
        var record = CaptureRecord(method: "GET", url: "http://localhost/")
        record.requestHeaders = [HTTPField("Cookie", "secret")]
        buffer.append(record); buffer.append(record); buffer.append(record)
        let batch = buffer.drain(limit: 1)
        #expect(batch.records.count == 1); #expect(batch.dropped == 1)
        #expect(batch.records[0].requestHeaders[0].value == "••••••")
        buffer.setPaused(true); buffer.append(record)
        #expect(buffer.drain().records.count == 1)
        #expect(buffer.drain().records.isEmpty)
    }
    @Test func documentRoundTripAndLoopValidation() throws {
        var doc = WorkspaceDocument(); doc.projects = [WorkflowProject(name: "demo")]
        #expect(try JSONDecoder().decode(WorkspaceDocument.self, from: JSONEncoder().encode(doc)) == doc)
        doc.proxy.upstream = .httpProxy(ProxyEndpoint(host: "localhost", port: doc.proxy.port))
        #expect(throws: WorkflowError.self) { try doc.proxy.validate() }
    }
}
