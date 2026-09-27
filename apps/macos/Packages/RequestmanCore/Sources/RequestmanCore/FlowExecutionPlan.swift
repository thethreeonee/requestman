import Foundation

public enum FlowPhase: Hashable, Sendable {
    case request
    case response
}

/// Conservative input requirements, including every reachable branch.
/// A static body replacement does not need to read the original body.
public enum StepInputRequirement: Equatable, Sendable {
    case metadataOnly
    case completeBody
}

public enum BodyPreparationMode: Equatable, Sendable {
    case streaming
    case buffered
}

/// One immutable environment version shared by both phases, never reloaded per field.
public struct EnvironmentSnapshot: Sendable {
    public let version: UUID
    public let name: String
    public let values: [String: String]

    public init(version: UUID = UUID(), name: String, values: [String: String]) {
        self.version = version
        self.name = name
        self.values = values
    }
}

/// Immutable execution requirements. Planning does not execute or interpret scripts.
public struct FlowExecutionPlan: Sendable {
    public let version: UUID
    public let environment: EnvironmentSnapshot
    public let requestBodyMode: BodyPreparationMode
    public let responseBodyMode: BodyPreparationMode
    private let requestRequirements: PhaseExecutionRequirements
    private let responseRequirements: PhaseExecutionRequirements

    public init(
        version: UUID = UUID(),
        environment: EnvironmentSnapshot,
        requestInputs: [StepInputRequirement],
        responseInputs: [StepInputRequirement]
    ) {
        self.version = version
        self.environment = environment
        requestBodyMode = requestInputs.contains(.completeBody) ? .buffered : .streaming
        responseBodyMode = responseInputs.contains(.completeBody) ? .buffered : .streaming
        requestRequirements = PhaseExecutionRequirements(needsCompleteBody: requestBodyMode == .buffered)
        responseRequirements = PhaseExecutionRequirements(needsCompleteBody: responseBodyMode == .buffered)
    }

    public init(version: UUID = UUID(), environment: EnvironmentSnapshot,
                requestSteps: [ModificationStep], responseSteps: [ModificationStep]) {
        self.version = version
        self.environment = environment
        requestRequirements = PhaseExecutionRequirements(steps: requestSteps, phase: .request)
        responseRequirements = PhaseExecutionRequirements(steps: responseSteps, phase: .response)
        requestBodyMode = requestRequirements.needsCompleteBody ? .buffered : .streaming
        responseBodyMode = responseRequirements.needsCompleteBody ? .buffered : .streaming
    }

    public func requirements(for phase: FlowPhase) -> PhaseExecutionRequirements {
        phase == .request ? requestRequirements : responseRequirements
    }

    public func bodyMode(for phase: FlowPhase) -> BodyPreparationMode {
        switch phase {
        case .request: requestBodyMode
        case .response: responseBodyMode
        }
    }
}
