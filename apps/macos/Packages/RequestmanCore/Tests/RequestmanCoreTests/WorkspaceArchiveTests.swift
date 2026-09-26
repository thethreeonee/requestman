import Foundation
import Testing
@testable import RequestmanCore

struct WorkspaceArchiveTests {
    private func populated() -> WorkspaceDocument {
        var document = WorkspaceDocument()
        var flow = RequestWorkflow(name: "完整请求")
        flow.method = "PATCH"; flow.matchTarget = .host; flow.matchRule = .equals; flow.matchPattern = "api.test"
        flow.matchHeaderEnabled = true; flow.matchHeaderName = "X-Env"; flow.matchHeaderPattern = "prod"
        var script = ModificationStep(kind: .script)
        script.value = "request.body = env.token; return request;"; script.scriptOptions = ScriptOptions()
        var response = ModificationStep(kind: .replaceBody); response.value = "完整响应内容"
        flow.requestSteps = [script]; flow.responseSteps = [response]
        var project = WorkflowProject(name: "项目"); project.symbol = "network"
        project.workflows = [flow, RequestWorkflow(name: "另一条")]
        document.projects = [project]
        var env = WorkspaceEnvironment(name: "生产"); env.variables = [NamedValue(name: "token", value: "secret")]
        document.environments = [env]; document.selectedEnvironmentID = env.id; document.proxy.port = 9191
        return document
    }

    @Test func fullRoundTripAppendsProjectsAndOverwritesOtherData() throws {
        let source = populated()
        let preferences: [String: Any] = ["captureMode": "browser", "selectedBrowserID": "org.test.browser",
                                        "requestLog.columnWidths.v1": ["request": 320.0], "futurePreference": [true, false]]
        let plist = try PropertyListSerialization.data(fromPropertyList: preferences, format: .binary, options: 0)
        let archive = try WorkspaceArchive.decode(WorkspaceArchive(document: source, preferences: plist).encoded())
        #expect(archive.document == source)
        #expect(try archive.preferenceValues()["selectedBrowserID"] as? String == "org.test.browser")
        #expect(try archive.preferenceValues()["futurePreference"] as? [Bool] == [true, false])
        var original = populated(); original.proxy.port = 9292
        let merged = try archive.merging(into: original)
        #expect(merged.projects.count == 2)
        #expect(merged.projects[0] == original.projects[0])
        #expect(merged.environments == source.environments && merged.selectedEnvironmentID == source.selectedEnvironmentID)
        #expect(merged.proxy == source.proxy)
        let repeated = try archive.merging(into: merged)
        #expect(Set(repeated.projects.map(\.id)).count == 3)
        #expect(Set(repeated.projects.flatMap(\.workflows).map(\.id)).count == 6)
        let stepIDs = repeated.projects.flatMap(\.workflows).flatMap { $0.requestSteps + $0.responseSteps }.map(\.id)
        #expect(Set(stepIDs).count == stepIDs.count)
        var copy = merged.projects[1]
        copy.id = source.projects[0].id
        for i in copy.workflows.indices {
            copy.workflows[i].id = source.projects[0].workflows[i].id
            for j in copy.workflows[i].requestSteps.indices { copy.workflows[i].requestSteps[j].id = source.projects[0].workflows[i].requestSteps[j].id }
            for j in copy.workflows[i].responseSteps.indices { copy.workflows[i].responseSteps[j].id = source.projects[0].workflows[i].responseSteps[j].id }
        }
        #expect(copy == source.projects[0], "Duplication preserves every content field")
    }

    @Test func scopedExportsPreserveMatchingAndBothLanesWithoutSettings() throws {
        let source = populated(), project = source.projects[0], flow = source.projects[0].workflows[0]
        let single = try WorkspaceArchive.decode(WorkspaceArchive(project: project, workflowID: flow.id).encoded())
        #expect(single.scope == .workflow && single.document.projects[0].workflows == [flow])
        #expect(single.preferences == nil && single.document.environments.isEmpty)
        let merged = try single.merging(into: source)
        #expect(merged.environments == source.environments && merged.proxy == source.proxy)
        #expect(merged.projects[1].workflows.count == 1)
        let group = try WorkspaceArchive.decode(WorkspaceArchive(project: project).encoded())
        #expect(group.scope == .project && group.document.projects == [project])
    }

    @Test func rejectsUnsupportedCorruptOrWrongScopeBeforeMerge() throws {
        let source = populated()
        let valid = try WorkspaceArchive(project: source.projects[0]).encoded()
        var json = try JSONSerialization.jsonObject(with: valid) as! [String: Any]
        json["version"] = 999
        #expect(throws: (any Error).self) { try WorkspaceArchive.decode(JSONSerialization.data(withJSONObject: json)) }
        json["version"] = 1; json["scope"] = "workflow"
        #expect(throws: (any Error).self) { try WorkspaceArchive.decode(JSONSerialization.data(withJSONObject: json)) }
        #expect(throws: (any Error).self) { try WorkspaceArchive.decode(Data("broken".utf8)) }
        #expect(throws: (any Error).self) { try WorkspaceArchive(document: source, preferences: Data()).merging(into: source) }
    }

    @Test func legacyProjectDefaultsAndProjectDisablePreserveIndividualState() throws {
        let legacy = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "name": "旧项目", "workflows": []])
        let decoded = try JSONDecoder().decode(WorkflowProject.self, from: legacy)
        #expect(decoded.enabled && decoded.symbol == "folder")
        var document = populated()
        document.projects[0].workflows[0].matchHeaderEnabled = false
        document.projects[0].workflows[1].enabled = false
        #expect(WorkflowEngine.match(document, method: "PATCH", url: "https://api.test/") != nil)
        document.projects[0].enabled = false
        #expect(WorkflowEngine.match(document, method: "PATCH", url: "https://api.test/") == nil)
        document = try JSONDecoder().decode(WorkspaceDocument.self, from: JSONEncoder().encode(document))
        #expect(!document.projects[0].enabled && document.projects[0].symbol == "network")
        document.projects[0].enabled = true
        #expect(WorkflowEngine.match(document, method: "PATCH", url: "https://api.test/") != nil)
        #expect(!document.projects[0].workflows[1].enabled)
    }
}
