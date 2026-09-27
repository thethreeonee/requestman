import Foundation

/// Data requirements and executor requirements are independent: file replacement does not read the original body.
public struct PhaseExecutionRequirements: Equatable, Sendable {
    public let needsCompleteBody: Bool
    public let requiresBackground: Bool
    public let hasScripts: Bool
    public let hasDelay: Bool
    public let hasBodyFile: Bool

    init(needsCompleteBody: Bool) {
        self.needsCompleteBody = needsCompleteBody
        requiresBackground = false
        hasScripts = false; hasDelay = false; hasBodyFile = false
    }

    public init(steps: [ModificationStep], phase: FlowPhase = .response) {
        var requirements: [StepExecutionRequirements] = []
        for step in steps where step.enabled {
            requirements.append(StepProcessors.processor(for: step.kind).requirements(for: step))
            // Local responses end the request phase, so later steps cannot demand input or admission.
            if phase == .request && (step.kind == .mock || step.kind == .redirect) { break }
        }
        hasScripts = requirements.contains(where: \.script)
        hasDelay = requirements.contains(where: \.delay)
        hasBodyFile = requirements.contains(where: \.bodyFile)
        needsCompleteBody = requirements.contains { $0.input == .completeBody }
        requiresBackground = requirements.contains(where: \.background)
    }
}
