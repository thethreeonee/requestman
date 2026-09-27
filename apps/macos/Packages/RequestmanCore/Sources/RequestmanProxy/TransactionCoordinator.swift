import Foundation
import RequestmanCore

/// Immutable business transaction shared by the streaming and background execution paths.
/// NIO owns transport state; this value owns matching, configuration snapshots and execution plans.
struct TransactionCoordinator: Sendable {
    let context: TransactionContext

    init(document: WorkspaceDocument, request: HTTPMessageDraft, id: UUID, date: Date) {
        let match = RuleMatchingEngine.match(document, method: request.method, url: request.url, headers: request.headers)
        context = TransactionContext(id: id, date: date, originalRequest: request, match: match)
    }

    var match: WorkflowMatch? { context.match }

    func steps(for phase: FlowPhase) -> [ModificationStep] {
        guard let match else { return [] }
        return phase == .request ? match.workflow.requestSteps : match.workflow.responseSteps
    }

    func requirements(for phase: FlowPhase) -> PhaseExecutionRequirements {
        context.plan.requirements(for: phase)
    }

    func execute(_ draft: inout HTTPMessageDraft, phase: FlowPhase, request: HTTPMessageDraft? = nil,
                 onTrace: ((StepExecutionTrace) -> Void)? = nil) throws -> ModificationExecutionResult {
        let execution = context.executionContext(for: phase, request: request,
            originalResponseStatus: phase == .response ? draft.status : nil)
        return try ModificationExecutionEngine.execute(steps(for: phase), to: &draft,
            context: execution, onTrace: onTrace)
    }

    func executeAsync(_ draft: inout HTTPMessageDraft, phase: FlowPhase, request: HTTPMessageDraft? = nil,
                      onTrace: ((StepExecutionTrace) -> Void)? = nil) async throws -> ModificationExecutionResult {
        let execution = context.executionContext(for: phase, request: request,
            originalResponseStatus: phase == .response ? draft.status : nil)
        return try await ModificationExecutionEngine.executeAsync(steps(for: phase), to: &draft,
            context: execution, onTrace: onTrace)
    }

    func cancel() { context.control.cancel() }
}
