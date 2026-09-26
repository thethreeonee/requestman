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
    @Test func prefixedEnvironmentAndLegacySyntax() throws {
        let id = UUID(), date = Date(timeIntervalSince1970: 123)
        #expect(try WorkflowEngine.resolve("{{$env.api}}/{{env.api}}", environment: ["api": "{{$uuid}}"], id: id, date: date) == "{{$uuid}}/{{$uuid}}")
        for text in ["{{$env.missing}}", "{{$unknown}}", "{{$env.api"] {
            #expect(throws: WorkflowError.self) { try WorkflowEngine.resolve(text, environment: [:], id: id, date: date) }
        }
    }
    @Test func multipleHeadersRoundTripAndLegacy() throws {
        var step = ModificationStep(kind: .setHeader); step.name = "X-Legacy"; step.value = "old"
        let legacy = try JSONDecoder().decode(ModificationStep.self, from: JSONEncoder().encode(step))
        #expect(legacy.headers == nil && legacy.headerEntries[0].name == "X-Legacy")
        step.headerEntries = [HeaderEntry(name: "X-Key", value: "{{$env.api}}"), HeaderEntry(name: "X-Trace", value: "{{$uuid}}"), HeaderEntry(name: "x-key", value: "last")]
        #expect(try JSONDecoder().decode(ModificationStep.self, from: JSONEncoder().encode(step)) == step)
        let id = UUID()
        for response in [false, true] {
            var draft = HTTPMessageDraft(method: "GET", url: "http://localhost/", headers: [HTTPField("X-Key", "old"), HTTPField("x-key", "duplicate"), HTTPField("Other", "keep")])
            _ = try WorkflowEngine.apply([step], response: response, to: &draft, environment: ["api": "new"], id: id, date: Date())
            #expect(draft.headers == [HTTPField("Other", "keep"), HTTPField("X-Trace", id.uuidString), HTTPField("x-key", "last")])
        }
        step.headerEntries = []
        var empty = HTTPMessageDraft(method: "GET", url: "http://localhost/")
        _ = try WorkflowEngine.apply([step], response: false, to: &empty, environment: [:], id: id, date: Date())
        #expect(empty.headers.isEmpty)
    }
    @Test func invalidHeaderBatchDoesNotPartiallyApply() {
        for entry in [HeaderEntry(name: "Host", value: "bad"), HeaderEntry(name: "Bad Name", value: "bad"), HeaderEntry(name: "X-Bad", value: "\r\nInjected: yes"), HeaderEntry(name: "X-Missing", value: "{{$env.missing}}") ] {
            var step = ModificationStep(kind: .setHeader)
            step.headerEntries = [HeaderEntry(name: "X-First", value: "changed"), entry]
            var draft = HTTPMessageDraft(method: "GET", url: "http://localhost/", headers: [HTTPField("X-First", "original")])
            #expect(throws: WorkflowError.self) { try WorkflowEngine.apply([step], response: false, to: &draft, environment: [:], id: UUID(), date: Date()) }
            #expect(draft.headers == [HTTPField("X-First", "original")])
        }
    }
    @Test func removeMultipleHeadersAndLegacyRoundTrip() throws {
        var step = ModificationStep(kind: .removeHeader); step.name = "X-Legacy"
        let legacy = try JSONDecoder().decode(ModificationStep.self, from: JSONEncoder().encode(step))
        #expect(legacy.headers == nil && legacy.headerEntries[0].name == "X-Legacy")
        step.headerEntries = [HeaderEntry(name: "x-key", value: "{{$env.unused}}"), HeaderEntry(name: "X-Trace"), HeaderEntry(name: "X-Missing")]
        #expect(try JSONDecoder().decode(ModificationStep.self, from: JSONEncoder().encode(step)) == step)
        for response in [false, true] {
            var draft = HTTPMessageDraft(method: "GET", url: "http://localhost/", headers: [HTTPField("X-Key", "one"), HTTPField("x-key", "two"), HTTPField("X-Trace", "trace"), HTTPField("X-Legacy", "old"), HTTPField("Other", "keep")])
            _ = try WorkflowEngine.apply([step, legacy], response: response, to: &draft, environment: [:], id: UUID(), date: Date())
            #expect(draft.headers == [HTTPField("Other", "keep")])
            var empty = step; empty.headerEntries = []
            _ = try WorkflowEngine.apply([empty], response: response, to: &draft, environment: [:], id: UUID(), date: Date())
            #expect(draft.headers == [HTTPField("Other", "keep")])
        }
    }
    @Test func invalidRemovalBatchDoesNotPartiallyApply() {
        for response in [false, true] {
            for name in ["Host", "Content-Length", "Bad Name", ""] {
                var step = ModificationStep(kind: .removeHeader)
                step.headerEntries = [HeaderEntry(name: "X-First"), HeaderEntry(name: name)]
                var draft = HTTPMessageDraft(method: "GET", url: "http://localhost/", headers: [HTTPField("X-First", "original")])
                #expect(throws: WorkflowError.self) { try WorkflowEngine.apply([step], response: response, to: &draft, environment: [:], id: UUID(), date: Date()) }
                #expect(draft.headers == [HTTPField("X-First", "original")])
            }
        }
    }
    @Test func mixedHeaderOperationsPreserveOrderAndIgnoreRemovedValues() throws {
        for response in [false, true] {
            var step = ModificationStep(kind: .setHeader)
            step.headerEntries = [
                HeaderEntry(operation: .remove, name: "x-key", value: "{{$env.unused}}"),
                HeaderEntry(operation: .set, name: "X-Key", value: "{{$env.key}}"),
                HeaderEntry(operation: .set, name: "X-Temporary", value: "temporary"),
                HeaderEntry(operation: .remove, name: "x-temporary"),
                HeaderEntry(operation: .remove, name: "X-Missing")
            ]
            let restored = try JSONDecoder().decode(ModificationStep.self, from: JSONEncoder().encode(step))
            #expect(restored == step)
            var draft = HTTPMessageDraft(method: "GET", url: "http://localhost/", headers: [HTTPField("X-Key", "old"), HTTPField("x-key", "duplicate")])
            _ = try WorkflowEngine.apply([restored], response: response, to: &draft, environment: ["key": "new"], id: UUID(), date: Date())
            #expect(draft.headers == [HTTPField("X-Key", "new")])
            step.headerEntries.append(HeaderEntry(operation: .set, name: "X-Fail", value: "{{$env.missing}}"))
            #expect(throws: WorkflowError.self) { try WorkflowEngine.apply([step], response: response, to: &draft, environment: ["key": "changed"], id: UUID(), date: Date()) }
            #expect(draft.headers == [HTTPField("X-Key", "new")])
        }
    }
    @Test func headerAddAppendsAndModifyUpdatesOnlyExistingMatches() throws {
        for response in [false, true] {
            var step = ModificationStep(kind: .setHeader)
            #expect(step.headerEntries.first?.operation == .add)
            step.headerEntries = [
                HeaderEntry(operation: .add, name: "X-Key", value: "added"),
                HeaderEntry(operation: .modify, name: "x-key", value: "{{$env.key}}"),
                HeaderEntry(operation: .modify, name: "X-Missing", value: "{{$env.unused}}"),
                HeaderEntry(operation: .add, name: "X-Key", value: "last"),
                HeaderEntry(operation: .add, name: "X-New", value: "new"),
                HeaderEntry(operation: .remove, name: "x-drop", value: "{{$env.unused}}")
            ]
            let original = [HTTPField("x-key", "one"), HTTPField("Other", "keep"), HTTPField("X-KEY", "two"), HTTPField("X-Drop", "drop")]
            var draft = HTTPMessageDraft(method: "GET", url: "http://localhost/", headers: original)
            let restored = try JSONDecoder().decode(ModificationStep.self, from: JSONEncoder().encode(step))
            #expect(restored == step)
            _ = try WorkflowEngine.apply([restored], response: response, to: &draft, environment: ["key": "changed"], id: UUID(), date: Date())
            #expect(draft.headers == [HTTPField("x-key", "changed"), HTTPField("Other", "keep"), HTTPField("X-KEY", "changed"), HTTPField("X-Key", "changed"), HTTPField("X-Key", "last"), HTTPField("X-New", "new")])
            for invalid in [HeaderEntry(operation: .add, name: "X-Bad", value: "\r\nInjected: yes"), HeaderEntry(operation: .modify, name: "X-Key", value: "{{$env.missing}}"), HeaderEntry(operation: .remove, name: "Host")] {
                var invalidStep = step; invalidStep.headerEntries.append(invalid)
                draft.headers = original
                #expect(throws: WorkflowError.self) { try WorkflowEngine.apply([invalidStep], response: response, to: &draft, environment: ["key": "changed"], id: UUID(), date: Date()) }
                #expect(draft.headers == original)
            }
            step.headerEntries = [HeaderEntry(operation: .add, name: "X-Key", value: "one"), HeaderEntry(operation: .add, name: "x-key", value: "two")]
            draft.headers = []
            _ = try WorkflowEngine.apply([step], response: response, to: &draft, environment: [:], id: UUID(), date: Date())
            #expect(draft.headers == [HTTPField("X-Key", "one"), HTTPField("x-key", "two")])
        }
    }
    @Test func oldHeaderArraysInheritTheirStepOperation() throws {
        for kind in [ModificationKind.setHeader, .removeHeader] {
            let id = UUID()
            let json = """
            {"id":"\(UUID())","kind":"\(kind.rawValue)","enabled":true,"name":"","value":"","status":200,
             "headers":[{"id":"\(id)","name":"X-Legacy","value":"old"}]}
            """
            let step = try JSONDecoder().decode(ModificationStep.self, from: Data(json.utf8))
            #expect(step.headers?.first?.operation == nil)
            #expect(step.headerEntries.first?.operation == (kind == .removeHeader ? .remove : .set))
            #expect(step.headerEntries.first?.id == id)
            #expect(try JSONDecoder().decode(ModificationStep.self, from: JSONEncoder().encode(step)) == step)
        }
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
    @Test func historyIsBoundedPausedAndKeepsCredentials() {
        let buffer = CaptureRecordBuffer(capacity: 2)
        var record = CaptureRecord(method: "GET", url: "http://localhost/")
        record.requestHeaders = [HTTPField("Cookie", "session=original"), HTTPField("Authorization", "secret")]
        record.sentHeaders = [HTTPField("cOoKiE", "session=modified")]
        record.receivedHeaders = [HTTPField("Set-Cookie", "session=server; HttpOnly"), HTTPField("Set-Cookie", "theme=dark")]
        record.responseHeaders = [HTTPField("set-cookie", "session=client; HttpOnly")]
        buffer.append(record); buffer.append(record); buffer.append(record)
        let batch = buffer.drain(limit: 1)
        #expect(batch.records.count == 1); #expect(batch.dropped == 1)
        #expect(batch.records[0].requestHeaders[0].value == "session=original")
        #expect(batch.records[0].requestHeaders[1].value == "secret")
        #expect(batch.records[0].sentHeaders == record.sentHeaders)
        #expect(batch.records[0].receivedHeaders == record.receivedHeaders)
        #expect(batch.records[0].responseHeaders == record.responseHeaders)
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
