import Foundation

struct ScriptProcessor: StepProcessor {
    func requirements(for step: ModificationStep) -> StepExecutionRequirements {
        .init(input: .completeBody, background: true, script: true)
    }
    func process(_ step: ModificationStep, draft: inout HTTPMessageDraft, context: ModificationExecutionContext) throws {
        draft = try context.scriptRuntime.run(source: step.value, draft: draft, context: context,
            timeoutMilliseconds: step.effectiveScriptOptions.timeoutMilliseconds)
    }
    func processAsync(_ step: ModificationStep, draft: inout HTTPMessageDraft, context: ModificationExecutionContext) async throws {
        draft = try await context.scriptRuntime.runAsync(source: step.value, draft: draft, context: context,
            timeoutMilliseconds: step.effectiveScriptOptions.timeoutMilliseconds, stepID: step.id)
    }
}
