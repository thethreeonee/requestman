import Foundation

public struct WorkflowMatch: Sendable {
    public let projectID: UUID?
    public let project: String
    public let workflow: RequestWorkflow
    public let environment: WorkspaceEnvironment?
    public init(projectID: UUID? = nil, project: String, workflow: RequestWorkflow, environment: WorkspaceEnvironment?) {
        self.projectID = projectID; self.project = project; self.workflow = workflow; self.environment = environment
    }
}

public enum RuleMatchingEngine {
    /// First enabled match in project order wins, keeping rule composition deterministic.
    public static func match(_ document: WorkspaceDocument, method: String, url: String, headers: [HTTPField] = []) -> WorkflowMatch? {
        for project in document.projects where project.enabled {
            if let workflow = project.workflows.first(where: { matches($0, method: method, url: url, headers: headers) }) {
                return WorkflowMatch(projectID: project.id, project: project.name, workflow: workflow, environment: document.environment)
            }
        }
        return nil
    }

    public static func matches(_ workflow: RequestWorkflow, method: String, url: String, headers: [HTTPField] = []) -> Bool {
        workflow.enabled && workflow.matchConditions.matches(method: method, url: url, headers: headers)
    }
    public static func matches(_ group: WorkflowMatchGroup, method: String, url: String, headers: [HTTPField]) -> Bool {
        guard group.enabled, group.validationError == nil else { return false }
        let results = group.conditions.filter(\.enabled).map { matches($0, method: method, url: url, headers: headers) }
            + group.groups.filter(\.enabled).map { matches($0, method: method, url: url, headers: headers) }
        return !results.isEmpty && (group.mode == .all ? results.allSatisfy { $0 } : results.contains(true))
    }
}
