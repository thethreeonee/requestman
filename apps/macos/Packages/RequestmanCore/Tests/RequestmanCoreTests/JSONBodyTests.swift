import Foundation
import Testing
@testable import RequestmanCore

struct JSONBodyTests {
    private func step(_ entries: [JSONEditEntry]) -> ModificationStep {
        var step = ModificationStep(kind: .modifyJSON); step.jsonEntries = entries; return step
    }
    private func apply(_ steps: [ModificationStep], text: String, response: Bool = false,
                       environment: [String: String] = [:]) throws -> HTTPMessageDraft {
        var draft = HTTPMessageDraft(method: "POST", url: "http://example.test/", headers: [HTTPField("ETag", "old")])
        draft.bodyText = text
        _ = try WorkflowEngine.apply(steps, response: response, to: &draft, environment: environment, id: UUID(), date: Date())
        return draft
    }
    @Test(arguments: [false, true]) func mixedOperationsAndExactValues(response: Bool) throws {
        let edit = step([
            .init(path: "data.name", value: #""张三""#),
            .init(operation: .modify, path: "data.count", value: "100"),
            .init(operation: .remove, path: "debug", value: "{{$env.unused}}"),
            .init(path: "data.flag", value: "true"), .init(path: "data.empty", value: "null"),
            .init(path: "data.list", value: "[1,2]"), .init(path: "data.object", value: "{}")
        ])
        let original = #"{"data":{"name":"old","count":1},"debug":true,"id":1234567890123456789012345678901234567890,"exponent":1.234567890123456789e+400,"escaped":"\u4f60"}"#
        let result = try apply([edit], text: original, response: response)
        #expect(result.replacementBody == #"{"data":{"name":"张三","count":100,"flag":true,"empty":null,"list":[1,2],"object":{}},"id":1234567890123456789012345678901234567890,"exponent":1.234567890123456789e+400,"escaped":"\u4f60"}"#)
        #expect(!result.headers.contains { $0.name == "ETag" })
    }
    @Test func arrayOrderQuotedKeysAndSequentialOperations() throws {
        let edit = step([
            .init(operation: .remove, path: "items[0]"),
            .init(path: "items[0].name", value: #""new""#),
            .init(path: "items[1]", value: "false"),
            .init(path: #"["a.b"][""]"#, value: "null")
        ])
        #expect(try apply([edit], text: #"{"items":[{}, {"name":"old"}], "a.b":{"":1}}"#).replacementBody == #"{"items":[{"name":"new"},false],"a.b":{"":null}}"#)
        #expect(try apply([step([.init(path: "[0]", value: "42")])], text: "[]").replacementBody == "[42]")
    }
    @Test func templatesLiteralModeAndNoOps() throws {
        var edit = step([.init(path: "{{$env.path}}", value: "{{$env.value}}")])
        #expect(try apply([edit], text: "{}", environment: ["path": "data", "value": "[1,true]"]).replacementBody == #"{"data":[1,true]}"#)
        edit.jsonEntries = [.init(path: "x", value: #""{{$env.missing}}""#)]; edit.literalValues = true
        #expect(try apply([edit], text: "{}").replacementBody == #"{"x":"{{$env.missing}}"}"#)
        let noop = step([.init(operation: .modify, path: "absent.child", value: "{{$env.missing}}"), .init(operation: .remove, path: "items[9]")])
        let result = try apply([noop], text: #"{ "items": [] }"#)
        #expect(!result.hasReplacementBody && result.headers.first?.name == "ETag")
        #expect(try apply([step([])], text: "not json").replacementBody == nil)
        #expect(try apply([step([.init(path: "x", value: "1")])], text: #"{ "x": 1 }"#).replacementBody == nil)
    }
    @Test func invalidInputPathsAndValuesAreAtomic() throws {
        let cases: [(String, JSONEditEntry)] = [
            ("{}", .init(path: "missing.child", value: "1")),
            (#"{"x":1}"#, .init(path: "x.y", value: "1")),
            ("[]", .init(path: "[1]", value: "1")),
            ("{}", .init(path: "x", value: "unquoted")),
            ("{}", .init(path: "x", value: "01")),
            ("{}", .init(path: "x", value: "[1,]")),
            ("{}", .init(path: "x", value: "NaN")),
            ("{}", .init(path: "a..b", value: "1")),
            ("{}", .init(path: "a[-1]", value: "1")),
            ("{}", .init(path: "a[0]b", value: "1")),
            ("{}", .init(path: "", value: "1")),
            ("{}", .init(path: "x", value: "{{$env.missing}}")),
            (#"{"x":1,"x":2}"#, .init(path: "x", value: "1")),
            ("{bad}", .init(path: "x", value: "1"))
        ]
        for (body, entry) in cases {
            var draft = HTTPMessageDraft(method: "POST", url: "http://example.test/")
            draft.bodyText = body
            var traces: [StepExecutionTrace] = []
            let edit = step(body.hasPrefix("{") ? [.init(path: "first", value: "true"), entry] : [entry])
            #expect(throws: WorkflowError.self) {
                try ModificationExecutionEngine.execute([edit], to: &draft,
                    context: .init(phase: .request, environment: [:], templateContext: .init(id: UUID(), date: Date(), request: draft)), onTrace: { traces.append($0) })
            }
            #expect(!draft.hasReplacementBody && draft.bodyText == body)
            #expect(traces.count == 1 && traces.first?.status == .failed)
        }
    }
    @Test func replacementCompositionPersistenceAndRequirements() throws {
        var replace = ModificationStep(kind: .replaceBody); replace.value = #"{"a":1}"#
        let edit = step([.init(path: "a", value: "2")])
        #expect(try apply([replace, edit], text: "not JSON").replacementBody == #"{"a":2}"#)
        replace.bodyEncoding = .base64; replace.value = Data(#"{"a":1}"#.utf8).base64EncodedString()
        #expect(try apply([replace, edit], text: "not JSON").replacementBody == #"{"a":2}"#)
        #expect(try JSONDecoder().decode(ModificationStep.self, from: JSONEncoder().encode(edit)) == edit)
        var workflow = RequestWorkflow(); workflow.requestSteps = [edit]; workflow.responseSteps = [edit]
        var project = WorkflowProject(); project.workflows = [workflow]
        var document = WorkspaceDocument(); document.projects = [project]
        #expect(try JSONDecoder().decode(WorkspaceDocument.self, from: JSONEncoder().encode(document)) == document)
        let archive = WorkspaceArchive(project: project)
        let imported = try WorkspaceArchive.decode(archive.encoded()).merging(into: WorkspaceDocument())
        #expect(imported.projects.first?.workflows.first?.requestSteps.first?.jsonEntries == edit.jsonEntries)
        for phase in [FlowPhase.request, .response] {
            let plan = PhaseExecutionRequirements(steps: [edit], phase: phase)
            #expect(plan.needsCompleteBody && plan.requiresBackground && !plan.hasScripts)
            var disabled = edit; disabled.enabled = false
            #expect(!PhaseExecutionRequirements(steps: [disabled], phase: phase).needsCompleteBody)
            #expect(!PhaseExecutionRequirements(steps: [step([])], phase: phase).needsCompleteBody)
        }
    }
}
