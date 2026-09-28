import Foundation
import Testing
@testable import RequestmanCore

struct WorkspaceArchiveTests {
    private func populated() -> WorkspaceDocument {
        var document = WorkspaceDocument()
        var flow = RequestWorkflow(name: "完整请求")
        flow.matchConditions = WorkflowMatchGroup(conditions: [
            MatchCondition(field: .method, operation: .equals, value: "PATCH"),
            MatchCondition(field: .host, operation: .equals, value: "api.test"),
            MatchCondition(field: .header, operation: .equals, name: "X-Env", value: "prod")])
        var script = ModificationStep(kind: .script)
        script.value = "request.body = env.token; return request;"; script.scriptOptions = ScriptOptions()
        var response = ModificationStep(kind: .replaceBody); response.value = "完整响应内容"
        flow.requestSteps = [script]; flow.responseSteps = [response]
        var project = WorkflowProject(name: "规则组"); project.symbol = "network"
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
            #expect(copy.workflows[i].matchConditions.id != source.projects[0].workflows[i].matchConditions.id)
            copy.workflows[i].matchConditions.id = source.projects[0].workflows[i].matchConditions.id
            for j in copy.workflows[i].matchConditions.conditions.indices {
                #expect(copy.workflows[i].matchConditions.conditions[j].id != source.projects[0].workflows[i].matchConditions.conditions[j].id)
                copy.workflows[i].matchConditions.conditions[j].id = source.projects[0].workflows[i].matchConditions.conditions[j].id
            }
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

    @Test func allRulesRoundTripPreservesGroupsAndAppendsWithoutReplacingSettings() throws {
        var source = populated()
        source.projects[0].setWorkflowsEnabled(false)
        source.projects.append(WorkflowProject(name: "空规则组"))
        let archive = try WorkspaceArchive.decode(WorkspaceArchive(projects: source.projects).encoded())
        #expect(archive.scope == .rules)
        #expect(archive.document.projects == source.projects)
        #expect(archive.preferences == nil && archive.document.environments.isEmpty)
        var current = populated()
        current.proxy.port = 9393
        current.httpsDecryption.decryptAllRequests = false
        current.httpsDecryption.domains = ["current.test"]
        let merged = try archive.merging(into: current)
        #expect(merged.projects.map(\.name) == current.projects.map(\.name) + source.projects.map(\.name))
        #expect(merged.projects[1].workflows.allSatisfy { !$0.enabled } && merged.projects[1].symbol == "network")
        #expect(merged.projects[2].workflows.isEmpty)
        var unchanged = merged; unchanged.projects = current.projects
        #expect(unchanged == current)
        let repeated = try archive.merging(into: merged)
        #expect(Set(repeated.projects.map(\.id)).count == 5)
        #expect(Set(repeated.projects.flatMap(\.workflows).map(\.id)).count == 6)
        let empty = try WorkspaceArchive.decode(WorkspaceArchive(projects: []).encoded())
        #expect(try empty.merging(into: current) == current)
    }

    @Test func importingWorkspaceAsRulesKeepsCurrentConfiguration() throws {
        let source = populated()
        let preferences = try PropertyListSerialization.data(fromPropertyList: ["captureMode": "browser"], format: .binary, options: 0)
        let backup = WorkspaceArchive(document: source, preferences: preferences)
        let rules = try backup.rulesArchive()
        #expect(rules.scope == .rules && rules.preferences == nil)
        var current = WorkspaceDocument(); current.proxy.port = 9494
        let merged = try rules.merging(into: current)
        #expect(merged.projects.count == source.projects.count)
        #expect(merged.environments.isEmpty && merged.selectedEnvironmentID == nil)
        #expect(merged.proxy == current.proxy)
    }

    @Test func singleRuleCreatesTimestampedGroupUsingImportTime() throws {
        let current = populated(), project = current.projects[0]
        let archive = try WorkspaceArchive(project: project, workflowID: project.workflows[0].id).rulesArchive()
        let zone = TimeZone(secondsFromGMT: 8 * 3600)!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 12, minute: 45, second: 34))!
        let merged = try archive.merging(into: current, importedAt: date, timeZone: zone)
        #expect(merged.projects[0] == project)
        #expect(merged.projects[1].name == "导入 2026/09/24 12:45:34")
        #expect(merged.projects[1].id != project.id)
        #expect(merged.projects[1].workflows.count == 1)
        #expect(merged.projects[1].workflows[0].id != project.workflows[0].id)
        #expect(merged.projects[1].workflows[0].requestSteps[0].value == project.workflows[0].requestSteps[0].value)
        #expect(merged.projects[1].workflows[0].responseSteps[0].value == project.workflows[0].responseSteps[0].value)
        let group = try WorkspaceArchive(project: project).merging(into: current, importedAt: date, timeZone: zone)
        #expect(group.projects[1].name == project.name)
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

    @Test func legacyProjectDefaultsAndGroupActionsUpdateEveryRule() throws {
        let legacy = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "name": "旧规则组", "workflows": []])
        let decoded = try JSONDecoder().decode(WorkflowProject.self, from: legacy)
        #expect(decoded.symbol == "folder")
        var document = populated()
        document.projects[0].workflows[0].matchConditions.conditions[2].enabled = false
        document.projects[0].workflows[1].enabled = false
        #expect(WorkflowEngine.match(document, method: "PATCH", url: "https://api.test/") != nil)
        let originalRules = document.projects[0].workflows
        document.projects[0].setWorkflowsEnabled(false)
        #expect(document.projects[0].workflows.allSatisfy { !$0.enabled })
        #expect(WorkflowEngine.match(document, method: "PATCH", url: "https://api.test/") == nil)
        document = try JSONDecoder().decode(WorkspaceDocument.self, from: JSONEncoder().encode(document))
        #expect(document.projects[0].symbol == "network")
        #expect(document.projects[0].workflows.allSatisfy { !$0.enabled })
        document.projects[0].setWorkflowsEnabled(true)
        #expect(document.projects[0].workflows.allSatisfy { $0.enabled })
        for (original, updated) in zip(originalRules, document.projects[0].workflows) {
            var expected = original
            expected.enabled = true
            #expect(updated == expected)
        }
        #expect(WorkflowEngine.match(document, method: "PATCH", url: "https://api.test/") != nil)
        var empty = WorkflowProject()
        empty.setWorkflowsEnabled(false)
        #expect(empty.workflows.isEmpty)
        empty.setWorkflowsEnabled(true)
        #expect(empty.workflows.isEmpty)
    }

    @Test func legacyGroupDisableMigratesToRulesWithoutKeepingAGroupGate() throws {
        var source = populated()
        source.projects[0].workflows[0].matchConditions.conditions[2].enabled = false
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(source.projects[0])) as! [String: Any]
        #expect(json["enabled"] == nil)
        json["enabled"] = false
        var project = try JSONDecoder().decode(WorkflowProject.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(project.workflows.allSatisfy { !$0.enabled })
        source.projects = [project]
        #expect(RuleMatchingEngine.match(source, method: "PATCH", url: "https://api.test/") == nil)
        project.workflows[0].enabled = true
        source.projects = [project]
        #expect(RuleMatchingEngine.match(source, method: "PATCH", url: "https://api.test/")?.workflow.id == project.workflows[0].id)
        #expect(!project.workflows[1].enabled)
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as! [String: Any]
        #expect(saved["enabled"] == nil)
        #expect(try JSONDecoder().decode(WorkflowProject.self, from: JSONEncoder().encode(project)) == project)
    }
}
