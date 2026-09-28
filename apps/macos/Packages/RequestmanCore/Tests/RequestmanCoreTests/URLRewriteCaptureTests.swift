import Foundation
import Testing
@testable import RequestmanCore

struct URLRewriteCaptureTests {
    private func match(_ group: WorkflowMatchGroup, url: String, steps: [ModificationStep] = [],
                       headers: [HTTPField] = []) throws -> WorkflowMatch {
        var workflow = RequestWorkflow()
        workflow.matchConditions = group
        workflow.requestSteps = steps
        return try #require(RuleMatchingEngine.match(workflow, project: "测试", environment: nil,
                                                     method: "POST", url: url, headers: headers))
    }

    private func rewrite(_ value: String, target: URLRewriteTarget = .fullURL) -> ModificationStep {
        var step = ModificationStep(kind: .rewriteURL)
        step.urlRewriteTarget = target
        step.value = value
        return step
    }

    @Test(arguments: [false, true])
    func capturesStayFrozenAcrossRewritesAndExecutionPaths(asynchronous: Bool) async throws {
        let original = "https://old.test/v2/items/a%2Fb?keep=%2f+%20"
        let steps = [rewrite("https://intermediate.test/changed?keep=%2f+%20"),
                     rewrite("$1.next.test:9443", target: .host), rewrite("/copy/$2", target: .path)]
        let rule = try match(.init(conditions: [MatchCondition(field: .url, operation: .regex,
            value: #"^https://old\.test/(v\d+)/items/([^?]+)"#)]), url: original, steps: steps)
        #expect(rule.regexCaptures == ["https://old.test/v2/items/a%2Fb", "v2", "a%2Fb"])
        var request = HTTPMessageDraft(method: "POST", url: original)
        request.bodyData = Data("payload".utf8)
        let transaction = TransactionContext(id: UUID(), date: Date(), originalRequest: request, match: rule)
        if asynchronous {
            _ = try await ModificationExecutionEngine.executeAsync(steps, to: &request,
                context: transaction.executionContext(for: .request))
        } else {
            _ = try ModificationExecutionEngine.execute(steps, to: &request,
                context: transaction.executionContext(for: .request))
        }
        #expect(request.url == "https://v2.next.test:9443/copy/a%2Fb?keep=%2f+%20")
        #expect(request.method == "POST" && request.bodyData == Data("payload".utf8))
        #expect(transaction.originalRequest.url == original)
        var full = request
        _ = try ModificationExecutionEngine.execute([rewrite("https://new.test/$1/$2")], to: &full,
            context: transaction.executionContext(for: .request))
        #expect(full.url == "https://new.test/v2/a%2Fb")
    }

    @Test func capturesSkipDisabledUnmatchedAndFailedBranches() throws {
        let url = "https://example.test/a/42"
        var disabled = MatchCondition(field: .path, operation: .regex, value: "(.*)")
        disabled.enabled = false
        let failed = WorkflowMatchGroup(conditions: [
            MatchCondition(field: .path, operation: .regex, value: "(a)"),
            MatchCondition(field: .method, operation: .equals, value: "DELETE")])
        var disabledGroup = WorkflowMatchGroup(conditions: [MatchCondition(field: .path, operation: .regex, value: "(.*)")])
        disabledGroup.enabled = false
        let selected = WorkflowMatchGroup(conditions: [
            MatchCondition(field: .path, operation: .regex, value: #"/a/(\d+)"#),
            MatchCondition(field: .url, operation: .regex, value: "(example)")])
        let group = WorkflowMatchGroup(mode: .any, conditions: [disabled,
            MatchCondition(field: .url, operation: .regex, value: "(absent)"),
            MatchCondition(field: .url, operation: .regex, value: "example")], groups: [failed, disabledGroup, selected])
        #expect(try match(group, url: url).regexCaptures == ["/a/42", "42"])
        let unmatched = WorkflowMatchGroup(conditions: failed.conditions)
        var workflow = RequestWorkflow(); workflow.matchConditions = unmatched
        #expect(RuleMatchingEngine.match(workflow, project: "测试", environment: nil, method: "POST", url: url) == nil)
    }

    @Test func liveDocumentSelectionPreservesCapturesAndLegacySerialization() throws {
        var workflow = RequestWorkflow()
        workflow.matchConditions = .init(conditions: [MatchCondition(field: .host, operation: .regex,
            value: #"^([A-Z]+)\.test$"#)])
        workflow.requestSteps = [rewrite("https://$1.local/")]
        workflow = try JSONDecoder().decode(RequestWorkflow.self, from: JSONEncoder().encode(workflow))
        var document = WorkspaceDocument()
        var project = WorkflowProject(name: "测试"); project.workflows = [workflow]
        document.projects = [project]
        let result = try #require(RuleMatchingEngine.match(document, method: "GET", url: "https://API.test/"))
        #expect(result.regexCaptures == ["api.test", "api"])
        #expect(result.workflow.requestSteps[0].value == "https://$1.local/")
    }

    @Test func unicodeOptionalGroupsAndRepeatedValuesUseFirstRegexMatch() throws {
        let group = WorkflowMatchGroup(conditions: [MatchCondition(field: .header, operation: .regex,
            name: "X-Route", value: "(😀中文)(?:-(next))?")])
        let result = try match(group, url: "https://example.test/", headers: [
            HTTPField("X-Route", "unmatched"), HTTPField("X-Route", "prefix😀中文 suffix😀中文-next"),
            HTTPField("X-Route", "😀中文-next")])
        #expect(result.regexCaptures == ["😀中文", "😀中文", ""])
        var request = HTTPMessageDraft(method: "GET", url: "https://example.test/?keep=1")
        let context = ModificationExecutionContext(phase: .request, environment: [:],
            templateContext: WorkflowTemplateContext(id: UUID(), date: Date(), request: request),
            regexCaptures: result.regexCaptures)
        _ = try ModificationExecutionEngine.execute([rewrite("/$1/$2", target: .path)], to: &request, context: context)
        #expect(request.url == "https://example.test/%F0%9F%98%80%E4%B8%AD%E6%96%87/?keep=1")
    }

    @Test func templatesAndCapturesExpandOnceWithEscapesAndMultiDigitReferences() throws {
        let context = WorkflowTemplateContext(id: UUID(), date: Date())
        let captures = ["whole", "{{$env.missing}}$2"] + (2...12).map(String.init)
        let text = "{{$env.host}}/$1/$12/$2/$0/$$1/$$/$x/$"
        #expect(try TemplateResolver.resolve(text, environment: ["host": "https://test/$9"], context: context,
            regexCaptures: captures) == "https://test/$9/{{$env.missing}}$2/12/2/whole/$1/$/$x/$")
        // Other step types retain the existing dollar syntax.
        #expect(try TemplateResolver.resolve("$1/$$", environment: [:], context: context) == "$1/$$")
    }

    @Test func invalidReferencesFailAtomicallyAndLiteralValuesStayLiteral() throws {
        for captures in [[], ["whole", "one"]] {
            for value in ["https://new.test/$2", "https://new.test/$999999999999999999999999999999"] {
                var request = HTTPMessageDraft(method: "GET", url: "https://old.test/")
                let context = ModificationExecutionContext(phase: .request, environment: [:],
                    templateContext: WorkflowTemplateContext(id: UUID(), date: Date()), regexCaptures: captures)
                var trace: [StepExecutionTrace] = []
                #expect(throws: WorkflowError.self) {
                    try ModificationExecutionEngine.execute([rewrite("https://prior.test/"), rewrite(value)],
                        to: &request, context: context, onTrace: { trace.append($0) })
                }
                #expect(request.url == "https://prior.test/")
                #expect(trace.map(\.status) == [.applied, .failed])
            }
        }
        var literal = rewrite("https://new.test/$1/$$")
        literal.literalValues = true
        var request = HTTPMessageDraft(method: "GET", url: "https://old.test/")
        _ = try WorkflowEngine.apply([literal], response: false, to: &request, environment: [:], id: UUID(), date: Date())
        #expect(request.url == literal.value)
    }
}
