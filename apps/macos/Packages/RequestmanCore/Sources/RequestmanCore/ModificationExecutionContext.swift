import Foundation

/// Immutable phase input. The mutable message and execution trace remain separate.
public struct ModificationExecutionContext: Sendable {
    public let regexCaptures: [String]
    public let phase: FlowPhase
    public let environment: [String: String]
    public let environmentTypes: [String: EnvironmentValueType]
    public let templateContext: WorkflowTemplateContext
    public let originalResponseStatus: Int?
    public let request: HTTPMessageDraft?
    public let control: ScriptExecutionControl
    public let scriptRuntime: any ScriptRuntime

    public init(phase: FlowPhase, environment: [String: String],
                environmentTypes: [String: EnvironmentValueType] = [:],
                templateContext: WorkflowTemplateContext, originalResponseStatus: Int? = nil,
                request: HTTPMessageDraft? = nil, control: ScriptExecutionControl = ScriptExecutionControl(),
                scriptRuntime: any ScriptRuntime = IsolatedScriptRuntime(), regexCaptures: [String] = []) {
        self.regexCaptures = regexCaptures
        self.phase = phase
        self.environment = environment
        self.environmentTypes = environmentTypes
        self.templateContext = templateContext
        self.originalResponseStatus = originalResponseStatus
        self.request = request
        self.control = control
        self.scriptRuntime = scriptRuntime
    }

    func resolve(_ value: String, step: ModificationStep) throws -> String {
        if step.literalValues == true { return value }
        return try TemplateResolver.resolve(value, environment: environment, context: templateContext,
                                            responseStatus: originalResponseStatus,
                                            regexCaptures: step.kind == .rewriteURL ? regexCaptures : nil)
    }
}
