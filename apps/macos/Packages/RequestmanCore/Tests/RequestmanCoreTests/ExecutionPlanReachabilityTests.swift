import Foundation
import Testing
@testable import RequestmanCore

struct ExecutionPlanReachabilityTests {
    private var fileStep: ModificationStep {
        var step = ModificationStep(kind: .replaceBody)
        step.bodySource = .file
        return step
    }

    @Test func requestLocalResponseDoesNotWaitForUnreachableScriptOrFile() {
        for kind in [ModificationKind.mock, .redirect] {
            let plan = FlowExecutionPlan(environment: .init(name: "test", values: [:]),
                requestSteps: [.init(kind: kind), .init(kind: .script), fileStep], responseSteps: [])
            let requirements = plan.requirements(for: .request)
            #expect(plan.bodyMode(for: .request) == .streaming)
            #expect(!requirements.needsCompleteBody && !requirements.requiresBackground)
            #expect(!requirements.hasScripts && !requirements.hasBodyFile)
        }
    }

    @Test func terminatingStepAndEarlierStepsKeepTheirRequirements() {
        var mockFile = ModificationStep(kind: .mock)
        mockFile.bodySource = .file
        let file = PhaseExecutionRequirements(steps: [mockFile, .init(kind: .script)], phase: .request)
        #expect(file.hasBodyFile && file.requiresBackground && !file.hasScripts && !file.needsCompleteBody)

        let script = PhaseExecutionRequirements(steps: [.init(kind: .script), mockFile], phase: .request)
        #expect(script.hasScripts && script.needsCompleteBody && script.hasBodyFile)
    }

    @Test func disabledLocalResponseDoesNotHideReachableSteps() {
        for kind in [ModificationKind.mock, .redirect] {
            var terminal = ModificationStep(kind: kind)
            terminal.enabled = false
            let requirements = PhaseExecutionRequirements(steps: [terminal, .init(kind: .script), fileStep],
                                                          phase: .request)
            #expect(requirements.hasScripts && requirements.hasBodyFile && requirements.needsCompleteBody)
        }
    }

    @Test func responseRedirectStillRunsFollowingScriptAndFile() {
        let steps = [ModificationStep(kind: .redirect), .init(kind: .script), fileStep]
        let plan = FlowExecutionPlan(environment: .init(name: "test", values: [:]),
                                     requestSteps: [], responseSteps: steps)
        let requirements = plan.requirements(for: .response)
        #expect(plan.bodyMode(for: .response) == .buffered)
        #expect(requirements.hasScripts && requirements.hasBodyFile && requirements.requiresBackground)
        #expect(PhaseExecutionRequirements(steps: steps) == requirements)
    }
}
