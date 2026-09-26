import Foundation
import Testing
@testable import RequestmanCore

struct URLModificationTests {
    private func apply(_ steps: [ModificationStep], url: String, environment: [String: String] = [:]) throws -> HTTPMessageDraft {
        var draft = HTTPMessageDraft(method: "GET", url: url)
        _ = try WorkflowEngine.apply(steps, response: false, to: &draft, environment: environment, id: UUID(), date: Date())
        return draft
    }

    @Test func queryPreservesUnrelatedBytesAndReplacesExactDuplicateNames() throws {
        var step = ModificationStep(kind: .setQueryParameter)
        step.name = "key"; step.value = "中文 &+=/#?"
        let original = "https://example.test/a%2fb?keep=%2f+%20&key=old&Key=upper&%6Bey=other&flag&&tail="
        let result = try apply([step], url: original)
        #expect(result.url == "https://example.test/a%2fb?keep=%2f+%20&key=%E4%B8%AD%E6%96%87%20%26%2B%3D%2F%23%3F&Key=upper&flag&&tail=")
        let items = URLComponents(string: result.url)?.queryItems ?? []
        #expect(items.filter { $0.name == "key" }.map(\.value) == [step.value])
    }

    @Test func queryAddsEmptyValuesAndResolvesNamesAndValues() throws {
        var step = ModificationStep(kind: .setQueryParameter)
        step.name = "{{env.name}}"; step.value = "{{env.value}}"
        let env = ["name": "a+b", "value": ""]
        for url in ["https://example.test/", "https://example.test/?"] {
            #expect(try apply([step], url: url, environment: env).url == "https://example.test/?a%2Bb=")
        }
        #expect(try apply([step], url: "https://example.test/?a+b=old", environment: env).url == "https://example.test/?a%2Bb=")
    }

    @Test func replacementIsLiteralCaseSensitiveAndSupportsDeletion() throws {
        var step = ModificationStep(kind: .replaceURLString)
        step.name = "a.b"; step.value = "{{env.target}}"
        #expect(try apply([step], url: "https://example.test/a.b/aXb/A.B?q=a.b", environment: ["target": "next"]).url ==
            "https://example.test/next/aXb/A.B?q=next")
        step.name = "/next"; step.value = ""
        #expect(try apply([step], url: "https://example.test/next/path").url == "https://example.test/path")
        step.name = "absent"
        #expect(try apply([step], url: "https://example.test/").url == "https://example.test/")
    }

    @Test func stepsComposeInOrderAndRoundTrip() throws {
        var query = ModificationStep(kind: .setQueryParameter); query.name = "version"; query.value = "v1"
        var replace = ModificationStep(kind: .replaceURLString); replace.name = "v1"; replace.value = "v2"
        var workflow = RequestWorkflow(); workflow.requestSteps = [query, replace]
        var project = WorkflowProject(); project.workflows = [workflow]
        var document = WorkspaceDocument(); document.projects = [project]
        let decoded = try JSONDecoder().decode(WorkspaceDocument.self, from: JSONEncoder().encode(document))
        #expect(decoded == document)
        let steps = decoded.projects[0].workflows[0].requestSteps
        #expect(try apply(steps, url: "https://example.test/v1").url == "https://example.test/v2?version=v2")
        replace.enabled = false
        #expect(try apply([query, replace], url: "https://example.test/v1").url == "https://example.test/v1?version=v1")
    }

    @Test func invalidEditsFailWithoutMutatingURLOrReportingApplied() {
        for kind in [ModificationKind.setQueryParameter, .replaceURLString] {
            var step = ModificationStep(kind: kind); step.value = "new"
            #expect(throws: WorkflowError.self) { try apply([step], url: "https://example.test/") }
            step.name = "key"
            var response = HTTPMessageDraft(method: "GET", url: "https://example.test/")
            #expect(throws: WorkflowError.self) {
                try WorkflowEngine.apply([step], response: true, to: &response, environment: [:], id: UUID(), date: Date())
            }
        }
        for replacement in ["file:///tmp/x", "https://user:pass@example.test/", "https://example.test/#fragment", "https://example.test/\r\n", "https://example.test/a b", "https://"] {
            var step = ModificationStep(kind: .replaceURLString)
            step.name = "https://example.test/"; step.value = replacement
            var draft = HTTPMessageDraft(method: "GET", url: step.name)
            var applied: [ModificationKind] = []
            #expect(throws: WorkflowError.self) {
                try WorkflowEngine.apply([step], response: false, to: &draft, environment: [:], id: UUID(), date: Date(), onApplied: { applied.append($0) })
            }
            #expect(draft.url == step.name && applied.isEmpty)
        }
    }
}
