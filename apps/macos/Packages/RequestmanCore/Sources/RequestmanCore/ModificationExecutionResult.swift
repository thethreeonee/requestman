import Foundation

public enum ExecutionDisposition: Equatable, Sendable {
    case forward
    case localResponse
}

public struct StepExecutionTrace: Sendable, Codable {
    public enum Status: String, Equatable, Sendable, Codable { case applied, failed, cancelled }
    public let stepID: UUID
    public let kind: ModificationKind
    public let phase: FlowPhase
    public let elapsed: Duration
    public let status: Status
    public let error: String?
}

public struct ModificationExecutionResult: Sendable {
    public let trace: [StepExecutionTrace]
    public let disposition: ExecutionDisposition
}
