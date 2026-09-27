import Foundation

/// Injectable script boundary shared by real capture and local execution.
public protocol ScriptRuntime: Sendable {
    func run(source: String, draft: HTTPMessageDraft, context: ModificationExecutionContext,
             timeoutMilliseconds: Int) throws -> HTTPMessageDraft
}

public struct IsolatedScriptRuntime: ScriptRuntime {
    public init() {}

    public func run(source: String, draft: HTTPMessageDraft, context: ModificationExecutionContext,
                    timeoutMilliseconds: Int) throws -> HTTPMessageDraft {
        try WorkflowScript.run(source: source, draft: draft, response: context.phase == .response,
            request: context.request, environment: context.environment, timeoutMilliseconds: timeoutMilliseconds,
            control: context.control, environmentTypes: context.environmentTypes)
    }
}
