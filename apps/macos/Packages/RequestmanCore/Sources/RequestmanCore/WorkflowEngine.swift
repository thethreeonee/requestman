import Foundation

/// Compatibility entry points. New capture and preview code use the dedicated engines.
public enum WorkflowEngine {
    public static let managedHeaders = HTTPMessageValidation.managedHeaders
    public static func match(_ document: WorkspaceDocument, method: String, url: String, headers: [HTTPField] = []) -> WorkflowMatch? {
        RuleMatchingEngine.match(document, method: method, url: url, headers: headers)
    }
    public static func resolve(_ template: String, environment: [String: String], id: UUID, date: Date) throws -> String {
        try TemplateResolver.resolve(template, environment: environment, id: id, date: date)
    }
    public static func resolve(_ template: String, environment: [String: String], context: WorkflowTemplateContext,
                               responseStatus: Int? = nil) throws -> String {
        try TemplateResolver.resolve(template, environment: environment, context: context, responseStatus: responseStatus)
    }
    public static func apply(_ steps: [ModificationStep], response: Bool, to draft: inout HTTPMessageDraft,
                             environment: [String: String], id: UUID, date: Date,
                             request: HTTPMessageDraft? = nil, control: ScriptExecutionControl? = nil,
                             templateContext: WorkflowTemplateContext? = nil, originalResponseStatus: Int? = nil,
                             environmentTypes: [String: EnvironmentValueType] = [:],
                             onApplied: ((ModificationKind) -> Void)? = nil) throws -> [String] {
        let context = ModificationExecutionContext(phase: response ? .response : .request, environment: environment,
            environmentTypes: environmentTypes,
            templateContext: templateContext ?? WorkflowTemplateContext(id: id, date: date, request: response ? request : draft),
            originalResponseStatus: response ? (originalResponseStatus ?? draft.status) : nil,
            request: request, control: control ?? ScriptExecutionControl())
        return try ModificationExecutionEngine.execute(steps, to: &draft, context: context,
            onApplied: { onApplied?($0.kind) }).trace.map { $0.kind.title }
    }
    public static func applyAsync(_ steps: [ModificationStep], response: Bool, to draft: inout HTTPMessageDraft,
                                  environment: [String: String], id: UUID, date: Date,
                                  request: HTTPMessageDraft? = nil, control: ScriptExecutionControl? = nil,
                                  templateContext: WorkflowTemplateContext? = nil,
                                  environmentTypes: [String: EnvironmentValueType] = [:],
                                  onApplied: ((ModificationKind) -> Void)? = nil) async throws -> [String] {
        let context = ModificationExecutionContext(phase: response ? .response : .request, environment: environment,
            environmentTypes: environmentTypes,
            templateContext: templateContext ?? WorkflowTemplateContext(id: id, date: date, request: response ? request : draft),
            originalResponseStatus: response ? draft.status : nil,
            request: request, control: control ?? ScriptExecutionControl())
        return try await ModificationExecutionEngine.executeAsync(steps, to: &draft, context: context,
            onApplied: { onApplied?($0.kind) }).trace.map { $0.kind.title }
    }
    public static func delayMilliseconds(_ value: String) throws -> Int {
        try ModificationExecutionEngine.delayMilliseconds(value)
    }
    static func clearBodyEncoding(_ draft: inout HTTPMessageDraft) { HTTPMessageValidation.clearBodyEncoding(&draft) }
    static func isToken(_ value: String) -> Bool { HTTPMessageValidation.isToken(value) }
}
