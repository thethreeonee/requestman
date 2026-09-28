import Foundation

public struct WorkflowMatch: Sendable {
    public let projectID: UUID?
    public let project: String
    public let workflow: RequestWorkflow
    public let environment: WorkspaceEnvironment?
    public let regexCaptures: [String]
    public init(projectID: UUID? = nil, project: String, workflow: RequestWorkflow, environment: WorkspaceEnvironment?, regexCaptures: [String] = []) {
        self.projectID = projectID; self.project = project; self.workflow = workflow; self.environment = environment
        self.regexCaptures = regexCaptures
    }
}

public enum RuleMatchingEngine {
    /// First enabled match in project order wins, keeping rule composition deterministic.
    public static func match(_ document: WorkspaceDocument, method: String, url: String, headers: [HTTPField] = []) -> WorkflowMatch? {
        for project in document.projects {
            for workflow in project.workflows {
                if let match = match(workflow, projectID: project.id, project: project.name,
                                     environment: document.environment, method: method, url: url, headers: headers) {
                    return match
                }
            }
        }
        return nil
    }

    /// Shared by live selection and local preview so capture values come from the same match.
    public static func match(_ workflow: RequestWorkflow, projectID: UUID? = nil, project: String,
                             environment: WorkspaceEnvironment?, method: String, url: String,
                             headers: [HTTPField] = []) -> WorkflowMatch? {
        guard workflow.enabled else { return nil }
        let result = evaluate(workflow.matchConditions, method: method, url: url, headers: headers)
        guard result.matched else { return nil }
        return WorkflowMatch(projectID: projectID, project: project, workflow: workflow,
                             environment: environment, regexCaptures: result.captures)
    }

    public static func matches(_ workflow: RequestWorkflow, method: String, url: String, headers: [HTTPField] = []) -> Bool {
        workflow.enabled && matches(workflow.matchConditions, method: method, url: url, headers: headers)
    }
    public static func matches(_ group: WorkflowMatchGroup, method: String, url: String, headers: [HTTPField]) -> Bool {
        evaluate(group, method: method, url: url, headers: headers).matched
    }

    private static func evaluate(_ group: WorkflowMatchGroup, method: String, url: String,
                                 headers: [HTTPField]) -> (matched: Bool, captures: [String]) {
        guard group.enabled, group.validationError == nil else { return (false, []) }
        let results = group.conditions.filter(\.enabled).map { condition -> (matched: Bool, captures: [String]) in
            guard condition.operation == .regex else {
                return (matches(condition, method: method, url: url, headers: headers), [])
            }
            let insensitive = [MatchField.host, .contentType].contains(condition.field)
            for value in values(for: condition, method: method, url: url, headers: headers) {
                if let match = WorkflowMatcher.regexMatch(condition.value, value: value, ignoreCase: insensitive) {
                    let captures = (0..<match.numberOfRanges).map { index in
                        Range(match.range(at: index), in: value).map { String(value[$0]) } ?? ""
                    }
                    return (true, captures.count > 1 ? captures : [])
                }
            }
            return (false, [])
        } + group.groups.filter(\.enabled).map { evaluate($0, method: method, url: url, headers: headers) }
        let matched = !results.isEmpty && (group.mode == .all ? results.allSatisfy(\.matched) : results.contains { $0.matched })
        // A failed branch contributes no captures. Keep one regex's numbering intact.
        return (matched, matched ? results.first { $0.matched && !$0.captures.isEmpty }?.captures ?? [] : [])
    }
}
