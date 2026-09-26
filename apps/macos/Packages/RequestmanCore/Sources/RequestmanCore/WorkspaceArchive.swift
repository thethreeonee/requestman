import Foundation

/// Portable configuration only. Certificates, browser profiles and proxy recovery journals
/// belong to the local machine and are never part of an archive.
public struct WorkspaceArchive: Codable, Sendable {
    public enum Scope: String, Codable, Sendable { case workspace, project, workflow }
    public let format: String
    public let version: Int
    public let scope: Scope
    public let document: WorkspaceDocument
    /// The app's persistent UserDefaults domain as a binary property list.
    public let preferences: Data?

    public init(document: WorkspaceDocument, preferences: Data) {
        format = "requestman.archive"; version = 1; scope = .workspace
        self.document = document; self.preferences = preferences
    }

    public init(project: WorkflowProject, workflowID: UUID? = nil) {
        format = "requestman.archive"; version = 1
        scope = workflowID == nil ? .project : .workflow
        var exported = project
        if let workflowID {
            exported.workflows = project.workflows.filter { $0.id == workflowID }
        }
        var document = WorkspaceDocument()
        document.projects = [exported]
        self.document = document; preferences = nil
    }

    public func validate() throws {
        guard format == "requestman.archive", version == 1, [1, 2].contains(document.version) else {
            throw WorkflowError.invalid("不支持此导出文件版本")
        }
        if scope == .workspace {
            _ = try preferenceValues()
        } else {
            guard preferences == nil, document.environments.isEmpty,
                  document.projects.count == 1,
                  scope != .workflow || document.projects[0].workflows.count == 1 else {
                throw WorkflowError.invalid("导出文件的条目范围不正确")
            }
        }
        let environmentIDs = document.environments.map(\.id)
        guard Set(environmentIDs).count == environmentIDs.count,
              document.selectedEnvironmentID == nil || environmentIDs.contains(document.selectedEnvironmentID!) else {
            throw WorkflowError.invalid("导出文件的环境数据不正确")
        }
    }

    public func preferenceValues() throws -> [String: Any] {
        guard let preferences,
              let values = try PropertyListSerialization.propertyList(from: preferences, format: nil) as? [String: Any] else {
            throw WorkflowError.invalid("导出文件缺少有效的设置数据")
        }
        return values
    }

    public func merging(into current: WorkspaceDocument) throws -> WorkspaceDocument {
        try validate()
        var result = scope == .workspace ? document : current
        result.version = 2
        // Every import appends a fresh project tree, even when importing the same file twice.
        result.projects = current.projects + document.projects.map { $0.duplicated() }
        return result
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> WorkspaceArchive {
        let archive = try JSONDecoder().decode(Self.self, from: data)
        try archive.validate()
        return archive
    }
}
