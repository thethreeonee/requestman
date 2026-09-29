import Foundation
import Testing
@testable import RequestmanCore

struct WorkspaceOrderingTests {
    private func populated() -> WorkspaceDocument {
        var document = WorkspaceDocument()
        var first = WorkflowProject(name: "第一组")
        var flow = RequestWorkflow(name: "完整规则")
        flow.requestSteps = [ModificationStep(kind: .setHeader)]
        flow.responseSteps = [ModificationStep(kind: .replaceBody)]
        first.workflows = [flow, RequestWorkflow(name: "第二条"), RequestWorkflow(name: "第三条")]
        var second = WorkflowProject(name: "第二组")
        var disabled = RequestWorkflow(name: "禁用规则")
        disabled.enabled = false
        second.workflows = [disabled]
        document.projects = [first, second, WorkflowProject(name: "空组")]
        document.environments = [WorkspaceEnvironment(name: "环境")]
        document.selectedEnvironmentID = document.environments[0].id
        document.proxy.port = 9191
        return document
    }

    @Test func movesWholeGroupsDownAndUpWithoutChangingContents() {
        var document = populated()
        let original = document
        let movedDown = document.moveProject(original.projects[0].id, to: 3)
        #expect(movedDown)
        #expect(document.projects == [original.projects[1], original.projects[2], original.projects[0]])
        let movedUp = document.moveProject(original.projects[0].id, to: 0)
        #expect(movedUp)
        #expect(document == original)
    }

    @Test func movesRulesToBothEndsWithinGroup() {
        var document = populated()
        let original = document
        let project = original.projects[0], rules = project.workflows
        let movedDown = document.moveWorkflow(rules[0].id, from: project.id, to: project.id, at: 3)
        #expect(movedDown)
        #expect(document.projects[0].workflows == [rules[1], rules[2], rules[0]])
        let movedUp = document.moveWorkflow(rules[0].id, from: project.id, to: project.id, at: 0)
        #expect(movedUp)
        #expect(document == original)
    }

    @Test func movesAcrossGroupsPreservingPayloadAndSettings() throws {
        var document = populated()
        let original = document
        let source = original.projects[0], destination = original.projects[1]
        let flow = source.workflows[0]
        let movedAcross = document.moveWorkflow(flow.id, from: source.id, to: destination.id, at: 0)
        #expect(movedAcross)
        #expect(document.projects[0].workflows == Array(source.workflows.dropFirst()))
        #expect(document.projects[1].workflows == [flow] + destination.workflows)
        let disabled = destination.workflows[0]
        let movedDisabled = document.moveWorkflow(disabled.id, from: destination.id, to: original.projects[2].id, at: 0)
        #expect(movedDisabled)
        #expect(document.projects[2].workflows == [disabled])
        #expect(document.projects[1].workflows == [flow])
        #expect(try JSONDecoder().decode(WorkspaceDocument.self, from: JSONEncoder().encode(document)) == document)
        document.projects = original.projects
        #expect(document == original)
    }

    @Test func movingLastRuleLeavesEmptySourceGroup() {
        var document = populated()
        let source = document.projects[1], destination = document.projects[2]
        let movedLast = document.moveWorkflow(source.workflows[0].id, from: source.id, to: destination.id, at: 0)
        #expect(movedLast)
        #expect(document.projects[1].id == source.id && document.projects[1].workflows.isEmpty)
        #expect(document.projects[2].workflows == source.workflows)
    }

    @Test func rejectsStaleInvalidAndUnchangedMovesAtomically() {
        var document = populated()
        let original = document, project = document.projects[0]
        let flow = project.workflows[0]
        for index in [-1, 0, 1, 4] {
            let movedGroup = document.moveProject(project.id, to: index)
            #expect(!movedGroup)
            let movedRule = document.moveWorkflow(flow.id, from: project.id, to: project.id, at: index)
            #expect(!movedRule)
            #expect(document == original)
        }
        let movedMissingGroup = document.moveProject(UUID(), to: 0)
        #expect(!movedMissingGroup)
        let movedMissingRule = document.moveWorkflow(UUID(), from: project.id, to: project.id, at: 0)
        #expect(!movedMissingRule)
        let movedFromMissingGroup = document.moveWorkflow(flow.id, from: UUID(), to: project.id, at: 0)
        #expect(!movedFromMissingGroup)
        let movedToMissingGroup = document.moveWorkflow(flow.id, from: project.id, to: UUID(), at: 0)
        #expect(!movedToMissingGroup)
        let movedStaleRule = document.moveWorkflow(flow.id, from: original.projects[1].id, to: project.id, at: 0)
        #expect(!movedStaleRule)
        let movedPastEnd = document.moveWorkflow(flow.id, from: project.id, to: original.projects[2].id, at: 1)
        #expect(!movedPastEnd)
        #expect(document == original)
    }

    @Test func matchingFollowsPersistedGroupAndRuleOrder() throws {
        var document = populated()
        let first = document.projects[0], second = document.projects[1]
        document.projects[1].workflows[0].enabled = true
        func match(_ document: WorkspaceDocument) -> UUID? {
            RuleMatchingEngine.match(document, method: "GET", url: "http://localhost:3000/test")?.workflow.id
        }
        #expect(match(document) == first.workflows[0].id)
        let movedRule = document.moveWorkflow(first.workflows[2].id, from: first.id, to: first.id, at: 0)
        #expect(movedRule)
        #expect(match(document) == first.workflows[2].id)
        let movedGroup = document.moveProject(second.id, to: 0)
        #expect(movedGroup)
        #expect(match(document) == second.workflows[0].id)
        let restored = try JSONDecoder().decode(WorkspaceDocument.self, from: JSONEncoder().encode(document))
        #expect(match(restored) == second.workflows[0].id)
    }
}
