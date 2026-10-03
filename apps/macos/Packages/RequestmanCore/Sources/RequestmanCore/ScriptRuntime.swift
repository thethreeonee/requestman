import Foundation

/// Injectable script boundary shared by real capture and local execution.
public protocol ScriptRuntime: Sendable {
    func run(source: String, draft: HTTPMessageDraft, context: ModificationExecutionContext,
             timeoutMilliseconds: Int) throws -> HTTPMessageDraft
    func runAsync(source: String, draft: HTTPMessageDraft, context: ModificationExecutionContext,
                  timeoutMilliseconds: Int, stepID: UUID?) async throws -> HTTPMessageDraft
}

extension ScriptRuntime {
    public func runAsync(source: String, draft: HTTPMessageDraft, context: ModificationExecutionContext,
                         timeoutMilliseconds: Int, stepID: UUID?) async throws -> HTTPMessageDraft {
        // Compatibility for injected synchronous runtimes; never run their work on a cooperative thread.
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try run(source: source, draft: draft, context: context,
                    timeoutMilliseconds: timeoutMilliseconds) })
            }
        }
    }
}

public struct IsolatedScriptRuntime: ScriptRuntime {
    public init() {}

    public func run(source: String, draft: HTTPMessageDraft, context: ModificationExecutionContext,
                    timeoutMilliseconds: Int) throws -> HTTPMessageDraft {
        try WorkflowScript.run(source: source, draft: draft, response: context.phase == .response,
            request: context.request, environment: context.environment, timeoutMilliseconds: timeoutMilliseconds,
            control: context.control, environmentTypes: context.environmentTypes)
    }
    public func runAsync(source: String, draft: HTTPMessageDraft, context: ModificationExecutionContext,
                         timeoutMilliseconds: Int, stepID: UUID?) async throws -> HTTPMessageDraft {
        try await WorkflowScript.runAsync(source: source, draft: draft, response: context.phase == .response,
            request: context.request, environment: context.environment, timeoutMilliseconds: timeoutMilliseconds,
            control: context.control, environmentTypes: context.environmentTypes, httpClient: context.httpClient,
            parentTransactionID: context.transactionID, stepID: stepID)
    }
}
