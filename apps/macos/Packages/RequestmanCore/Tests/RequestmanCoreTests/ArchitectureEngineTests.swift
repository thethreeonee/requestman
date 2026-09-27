import Foundation
import Testing
@testable import RequestmanCore

struct ArchitectureEngineTests {
    private func context(_ phase: FlowPhase = .request, control: ScriptExecutionControl = .init()) -> ModificationExecutionContext {
        .init(phase: phase, environment: [:], templateContext: .init(id: UUID(), date: Date()),
              originalResponseStatus: phase == .response ? 200 : nil, control: control)
    }

    @Test func transactionFreezesRulesEnvironmentAndOriginalRequestAcrossPhases() throws {
        var document = WorkspaceDocument()
        var environment = WorkspaceEnvironment(name: "dev")
        environment.variables = [NamedValue(name: "token", value: "old")]
        document.environments = [environment]; document.selectedEnvironmentID = environment.id
        var workflow = RequestWorkflow(name: "rule")
        workflow.matchConditions = .init(conditions: [.init(field: .url, operation: .contains, value: "original")])
        var requestHeader = ModificationStep(kind: .setHeader)
        requestHeader.name = "X-Snapshot"; requestHeader.value = "{{$env.token}}/{{$request.url}}/{{$randomHex}}"
        var responseHeader = requestHeader; responseHeader.id = UUID()
        workflow.requestSteps = [requestHeader]; workflow.responseSteps = [responseHeader]
        var project = WorkflowProject(); project.workflows = [workflow]; document.projects = [project]
        let original = HTTPMessageDraft(method: "GET", url: "https://original.test/")
        let match = try #require(RuleMatchingEngine.match(document, method: original.method, url: original.url))
        #expect(match.projectID == project.id)
        let transaction = TransactionContext(id: UUID(), date: Date(), originalRequest: original, match: match)
        document.environments[0].variables[0].value = "changed"
        document.projects[0].workflows[0].responseSteps = []
        var request = original; request.url = "https://rewritten.test/"
        _ = try ModificationExecutionEngine.execute(transaction.match!.workflow.requestSteps, to: &request,
                                                     context: transaction.executionContext(for: .request))
        var response = HTTPMessageDraft(method: "GET", url: request.url)
        _ = try ModificationExecutionEngine.execute(transaction.match!.workflow.responseSteps, to: &response,
            context: transaction.executionContext(for: .response, request: request, originalResponseStatus: 200))
        #expect(request.headers == response.headers)
        #expect(request.headers[0].value.hasPrefix("old/https://original.test//"))
        #expect(transaction.originalRequest.url == original.url)
    }

    @Test func failedStepIsAtomicAndEarlierCommitsArePreserved() throws {
        var first = ModificationStep(kind: .setHeader); first.name = "X-First"; first.value = "kept"
        var body = ModificationStep(kind: .replaceBody)
        body.bodyEncoding = .base64; body.value = "bmV3"; body.bodyContentEncoding = "bad\r\nencoding"
        var draft = HTTPMessageDraft(method: "GET", url: "https://test/", headers: [HTTPField("ETag", "original")])
        draft.replacementBody = "original"
        var traces: [StepExecutionTrace] = []
        #expect(throws: WorkflowError.self) {
            try ModificationExecutionEngine.execute([first, body], to: &draft, context: context(), onTrace: { traces.append($0) })
        }
        #expect(draft.replacementBody == "original" && draft.replacementBodyData == nil)
        #expect(draft.headers == [HTTPField("ETag", "original"), HTTPField("X-First", "kept")])
        #expect(traces.map(\.stepID) == [first.id, body.id])
        #expect(traces.map(\.status) == [.applied, .failed])
        #expect(traces[1].error != nil)
    }

    @Test func processorRequirementsKeepStreamingSeparateFromBackgroundWork() {
        for kind in ModificationKind.allCases {
            let requirements = PhaseExecutionRequirements(steps: [.init(kind: kind)])
            #expect(requirements.needsCompleteBody == (kind == .script))
            #expect(requirements.requiresBackground == (kind == .script || kind == .delay))
            #expect(requirements.hasScripts == (kind == .script))
            #expect(requirements.hasDelay == (kind == .delay))
        }
        var file = ModificationStep(kind: .replaceBody); file.bodySource = .file
        let fileRequirements = PhaseExecutionRequirements(steps: [file])
        #expect(fileRequirements.hasBodyFile && fileRequirements.requiresBackground)
        #expect(!fileRequirements.needsCompleteBody)
        file.enabled = false
        #expect(!PhaseExecutionRequirements(steps: [file]).requiresBackground)
        let plan = FlowExecutionPlan(environment: .init(name: "dev", values: [:]),
            requestSteps: [.init(kind: .script)], responseSteps: [.init(kind: .delay)])
        #expect(plan.bodyMode(for: .request) == .buffered)
        #expect(plan.bodyMode(for: .response) == .streaming)
        #expect(plan.requirements(for: .response).requiresBackground)
    }

    @Test func mockAndRedirectTerminateOnlyRequestPhase() throws {
        for kind in [ModificationKind.mock, .redirect] {
            var terminal = ModificationStep(kind: kind)
            terminal.status = kind == .mock ? 200 : 302
            terminal.value = kind == .mock ? "mock" : "https://destination.test/"
            var later = ModificationStep(kind: .setHeader); later.name = "X-Later"; later.value = "later"
            var draft = HTTPMessageDraft(method: "GET", url: "https://test/")
            let result = try ModificationExecutionEngine.execute([terminal, later], to: &draft, context: context())
            #expect(result.disposition == .localResponse && result.trace.map(\.stepID) == [terminal.id])
            if kind == .redirect {
                let responseResult = try ModificationExecutionEngine.execute([terminal, later], to: &draft, context: context(.response))
                #expect(responseResult.disposition == .forward && responseResult.trace.count == 2)
            }
        }
    }

    @Test func cancellationEmitsTraceWithoutCommittingNextStep() async throws {
        let control = ScriptExecutionControl()
        var delay = ModificationStep(kind: .delay); delay.value = "10000"
        var status = ModificationStep(kind: .setStatus); status.status = 201
        var draft = HTTPMessageDraft(method: "GET", url: "https://test/")
        var traces: [StepExecutionTrace] = []
        let canceller = Task { try await Task.sleep(for: .milliseconds(20)); control.cancel() }
        do {
            _ = try await ModificationExecutionEngine.executeAsync([delay, status], to: &draft,
                context: context(.response, control: control), onTrace: { traces.append($0) })
            Issue.record("Cancelled execution succeeded")
        } catch { #expect(error is WorkflowError) }
        try await canceller.value
        #expect(draft.status == 200)
        #expect(traces.map(\.stepID) == [delay.id])
        #expect(traces.map(\.status) == [.cancelled])
    }

    @Test func diagnosisAndLiveMatchingUseIdenticalNestedConditionSemantics() {
        var workflow = RequestWorkflow(name: "rule")
        workflow.matchConditions = .init(mode: .any, groups: [
            .init(conditions: [.init(field: .method, operation: .equals, value: "POST")]),
            .init(conditions: [.init(field: .header, operation: .equals, name: "X-Test", value: "yes")])
        ])
        for method in ["GET", "POST"] {
            for headers in [[], [HTTPField("x-test", "yes")]] {
                let match = RuleMatchingEngine.matches(workflow, method: method, url: "https://test/", headers: headers)
                let diagnosis = RuleMatchingEngine.evaluateConditions(workflow, method: method, url: "https://test/", headers: headers)
                #expect(match == diagnosis.matched)
            }
        }
    }
}
