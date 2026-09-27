import Foundation

struct ScriptProcessor: StepProcessor {
    func requirements(for step: ModificationStep) -> StepExecutionRequirements {
        .init(input: .completeBody, background: true, script: true)
    }
    func process(_ step: ModificationStep, draft: inout HTTPMessageDraft, context: ModificationExecutionContext) throws {
        draft = try context.scriptRuntime.run(source: step.value, draft: draft, context: context,
            timeoutMilliseconds: (step.scriptOptions ?? ScriptOptions()).timeoutMilliseconds)
    }
}
