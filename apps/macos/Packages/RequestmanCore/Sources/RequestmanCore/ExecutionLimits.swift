import Foundation

public enum ExecutionResourceError: Error, Equatable, Sendable {
    case invalidLimits
    case queueFull
    case timedOut
    case bodyTooLarge
    case bodyBudgetExhausted
    case oversizedChunk
    case bodyAlreadyPrepared
    case executionFinished
}

/// Initial, configurable safety limits, not measured throughput targets.
public struct ExecutionLimits: Sendable {
    public let maximumActive: Int
    public let maximumWaiting: Int
    public let maximumBodyBytes: Int
    public let maximumBufferedBytes: Int
    public let readChunkBytes: Int
    public let eventCapacity: Int
    public let maximumEventBatch: Int
    public let timeout: Duration

    public init(
        maximumActive: Int = 16,
        maximumWaiting: Int = 32,
        maximumBodyBytes: Int = 4 * 1_024 * 1_024,
        maximumBufferedBytes: Int = 64 * 1_024 * 1_024,
        readChunkBytes: Int = 64 * 1_024,
        eventCapacity: Int = 2_048,
        maximumEventBatch: Int = 128,
        timeout: Duration = .seconds(30)
    ) throws {
        guard maximumActive > 0, maximumWaiting >= 0,
              maximumBodyBytes > 0, maximumBodyBytes < Int.max,
              maximumBufferedBytes > 0, readChunkBytes > 0,
              readChunkBytes <= maximumBufferedBytes,
              eventCapacity > 0, maximumEventBatch > 0,
              maximumEventBatch <= eventCapacity, timeout > .zero else {
            throw ExecutionResourceError.invalidLimits
        }
        self.maximumActive = maximumActive
        self.maximumWaiting = maximumWaiting
        self.maximumBodyBytes = maximumBodyBytes
        self.maximumBufferedBytes = maximumBufferedBytes
        self.readChunkBytes = readChunkBytes
        self.eventCapacity = eventCapacity
        self.maximumEventBatch = maximumEventBatch
        self.timeout = timeout
    }
}
