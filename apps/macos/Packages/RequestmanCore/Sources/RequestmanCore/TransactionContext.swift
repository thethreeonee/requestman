import Foundation

/// One request's frozen rule, environment and template values, shared by both phases.
public struct TransactionContext: Sendable {
    public let id: UUID
    public let date: Date
    public let originalRequest: HTTPMessageDraft
    public let match: WorkflowMatch?
    public let templateContext: WorkflowTemplateContext
    public let control: ScriptExecutionControl
    public let plan: FlowExecutionPlan
    public let httpClient: (any ScriptHTTPClient)?
    public let isPreview: Bool

    public init(id: UUID, date: Date, originalRequest: HTTPMessageDraft, match: WorkflowMatch?,
                control: ScriptExecutionControl = ScriptExecutionControl(), httpClient: (any ScriptHTTPClient)? = nil,
                isPreview: Bool = false) {
        self.id = id
        self.date = date
        self.originalRequest = originalRequest
        self.match = match
        self.control = control
        self.httpClient = httpClient
        self.isPreview = isPreview
        templateContext = WorkflowTemplateContext(id: id, date: date, request: originalRequest)
        plan = FlowExecutionPlan(environment: EnvironmentSnapshot(name: match?.environment?.name ?? "无环境",
            values: match?.environment?.values ?? [:]), requestSteps: match?.workflow.requestSteps ?? [],
            responseSteps: match?.workflow.responseSteps ?? [])
    }

    public func executionContext(for phase: FlowPhase, request: HTTPMessageDraft? = nil,
                                 originalResponseStatus: Int? = nil) -> ModificationExecutionContext {
        ModificationExecutionContext(phase: phase, environment: plan.environment.values,
            environmentTypes: match?.environment?.valueTypes ?? [:], templateContext: templateContext,
            originalResponseStatus: originalResponseStatus, request: request, control: control,
            regexCaptures: match?.regexCaptures ?? [], httpClient: httpClient, transactionID: isPreview ? nil : id)
    }
}
