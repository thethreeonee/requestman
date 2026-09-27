import Foundation

/// A local condition check. Workflow/project enablement and step execution are intentionally excluded.
public struct WorkflowMatchTest: Sendable {
    public struct Condition: Sendable {
        public let name: String
        public let matched: Bool
        public let detail: String
        public let highlight: NSRange?
    }

    public let error: String?
    public let conditions: [Condition]
    public var groupMatched = false
    public var matched: Bool { error == nil && groupMatched }

    public static func validationError(for workflow: RequestWorkflow) -> String? {
        workflow.matchConditions.validationError
    }

    public static func evaluate(_ workflow: RequestWorkflow, method: String, url: String, headers: [HTTPField]) -> Self {
        RuleMatchingEngine.evaluateConditions(workflow, method: method, url: url, headers: headers)
    }
}
