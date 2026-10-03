import Foundation
import Testing
import RequestmanCore
@testable import RequestmanProxy

struct TransactionCoordinatorTests {
    @Test func previewDoesNotLinkAuxiliaryTrafficToASampleParentRecord() {
        let id = UUID(), request = HTTPMessageDraft(method: "GET", url: "http://example.test/")
        let live = TransactionContext(id: id, date: Date(), originalRequest: request, match: nil)
        let preview = TransactionContext(id: id, date: Date(), originalRequest: request, match: nil, isPreview: true)
        #expect(live.executionContext(for: .request).transactionID == id)
        #expect(preview.executionContext(for: .request).transactionID == nil)
    }

    @Test func configurationAndTemplatesStayFrozenAcrossPhasesAndRefreshForNextTransaction() throws {
        var document = workspace()
        var environment = WorkspaceEnvironment(name: "first")
        environment.variables = [NamedValue(name: "token", value: "old")]
        document.environments = [environment]
        document.selectedEnvironmentID = environment.id
        var header = ModificationStep(kind: .setHeader)
        header.headerEntries = [HeaderEntry(name: "X-Token", value: "{{$env.token}}"),
            HeaderEntry(name: "X-Original", value: "{{$request.url}}"),
            HeaderEntry(name: "X-Random", value: "{{$randomHex}}")]
        document.projects[0].workflows[0].requestSteps = [header]
        document.projects[0].workflows[0].responseSteps = [header]
        let original = HTTPMessageDraft(method: "GET", url: "http://example.test/before")
        let first = TransactionCoordinator(document: document, request: original, id: UUID(), date: Date())
        var request = original
        _ = try first.execute(&request, phase: .request)
        request.url = "http://example.test/after"
        document.environments[0].variables[0].value = "new"
        document.projects[0].workflows[0].name = "changed"
        var response = HTTPMessageDraft(method: "GET", url: request.url, status: 200)
        _ = try first.execute(&response, phase: .response, request: request)
        #expect(response.headers == request.headers)
        #expect(response.headers.contains { $0.name == "X-Token" && $0.value == "old" })
        #expect(response.headers.contains { $0.name == "X-Original" && $0.value == original.url })
        let second = TransactionCoordinator(document: document, request: original, id: UUID(), date: Date())
        var next = original
        _ = try second.execute(&next, phase: .request)
        #expect(second.match?.workflow.name == "changed")
        #expect(next.headers.contains { $0.name == "X-Token" && $0.value == "new" })
    }

    @Test func failureRetainsCompletedTraceAndDoesNotCommitTheFailedStep() throws {
        var document = workspace()
        var first = ModificationStep(kind: .setHeader); first.name = "X-First"; first.value = "ok"
        var invalid = ModificationStep(kind: .setHeader)
        invalid.headerEntries = [HeaderEntry(name: "X-Partial", value: "no"), HeaderEntry(name: "Invalid\nName", value: "bad")]
        document.projects[0].workflows[0].requestSteps = [first, invalid]
        var draft = HTTPMessageDraft(method: "GET", url: "http://example.test/")
        let transaction = TransactionCoordinator(document: document, request: draft, id: UUID(), date: Date())
        var trace: [StepExecutionTrace] = []
        #expect(throws: (any Error).self) { _ = try transaction.execute(&draft, phase: .request, onTrace: { trace.append($0) }) }
        #expect(trace.map(\.status) == [.applied, .failed])
        #expect(trace.map(\.stepID) == [first.id, invalid.id])
        #expect(draft.headers.contains { $0.name == "X-First" })
        #expect(!draft.headers.contains { $0.name == "X-Partial" })
    }

    @Test func mockDispositionAndResponsePhaseShareTheSameTransaction() throws {
        var document = workspace()
        var mock = ModificationStep(kind: .mock); mock.status = 201; mock.value = "local"
        var status = ModificationStep(kind: .setStatus); status.status = 202
        document.projects[0].workflows[0].requestSteps = [mock]
        document.projects[0].workflows[0].responseSteps = [status]
        var draft = HTTPMessageDraft(method: "GET", url: "http://example.test/")
        let transaction = TransactionCoordinator(document: document, request: draft, id: UUID(), date: Date())
        let request = try transaction.execute(&draft, phase: .request)
        #expect(request.disposition == .localResponse)
        _ = try transaction.execute(&draft, phase: .response)
        #expect(draft.status == 202)
    }

    @Test func cancellationSkipsRemainingWorkAndHasItsOwnTraceStatus() async throws {
        var document = workspace()
        var delay = ModificationStep(kind: .delay); delay.value = "1000"
        var header = ModificationStep(kind: .setHeader); header.name = "X-Later"; header.value = "no"
        document.projects[0].workflows[0].responseSteps = [delay, header]
        var draft = HTTPMessageDraft(method: "GET", url: "http://example.test/")
        let transaction = TransactionCoordinator(document: document, request: draft, id: UUID(), date: Date())
        transaction.cancel()
        var trace: [StepExecutionTrace] = []
        await #expect(throws: (any Error).self) {
            _ = try await transaction.executeAsync(&draft, phase: .response, onTrace: { trace.append($0) })
        }
        #expect(trace.map(\.status) == [.cancelled])
        #expect(draft.headers.isEmpty)
    }

    private func workspace() -> WorkspaceDocument {
        var workflow = RequestWorkflow()
        workflow.matchConditions.conditions = [MatchCondition(field: .url, operation: .beginsWith, value: "http://example.test/")]
        var project = WorkflowProject(name: "test"); project.workflows = [workflow]
        var document = WorkspaceDocument(); document.projects = [project]
        return document
    }
}
