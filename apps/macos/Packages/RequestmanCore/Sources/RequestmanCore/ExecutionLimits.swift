import Foundation

public enum ExecutionResourceError: Error, Equatable, Sendable {
    case invalidLimits
    case queueFull
    case timedOut
    case oversizedChunk
    case bodyAlreadyPrepared
    case executionFinished
}

/// Initial, configurable safety limits, not measured throughput targets.
public struct ExecutionLimits: Sendable {
    public let maximumActive: Int
    public let maximumWaiting: Int
    public let readChunkBytes: Int
    public let eventCapacity: Int
    public let maximumEventBatch: Int
    public let timeout: Duration

    public init(
        maximumActive: Int = 16,
        maximumWaiting: Int = 32,
        readChunkBytes: Int = 64 * 1_024,
        eventCapacity: Int = 2_048,
        maximumEventBatch: Int = 128,
        timeout: Duration = .seconds(30)
    ) throws {
        guard maximumActive > 0, maximumWaiting >= 0,
              readChunkBytes > 0, eventCapacity > 0, maximumEventBatch > 0,
              maximumEventBatch <= eventCapacity, timeout > .zero else {
            throw ExecutionResourceError.invalidLimits
        }
        self.maximumActive = maximumActive
        self.maximumWaiting = maximumWaiting
        self.readChunkBytes = readChunkBytes
        self.eventCapacity = eventCapacity
        self.maximumEventBatch = maximumEventBatch
        self.timeout = timeout
    }
}
