import Foundation
import os

/// Pull-based transport boundary. Readers must honor the chunk limit, propagate
/// task cancellation, and not prefetch into an unbounded queue. Nil means EOF;
/// a returned chunk must be nonempty. Supply decoded bytes when editing a body.
public protocol BodyReader: Sendable {
    func read(maximumBytes: Int) async throws -> Data?
}

/// Accounts retained payload bytes, not allocator overhead, transport buffers,
/// decompression scratch space or copies made by downstream consumers.
public final class BodyBufferBudget: Sendable {
    private let used = OSAllocatedUnfairLock(initialState: 0)
    public let capacity: Int

    public init(capacity: Int) throws {
        guard capacity > 0 else { throw ExecutionResourceError.invalidLimits }
        self.capacity = capacity
    }

    public var reservedBytes: Int { used.withLock { $0 } }

    func reserve(_ count: Int) throws {
        try used.withLock { used in
            guard count >= 0, count <= capacity - used else {
                throw ExecutionResourceError.bodyBudgetExhausted
            }
            used += count
        }
    }

    func release(_ count: Int) {
        used.withLock { $0 -= count }
    }
}

/// Share this owner between original/current views. No implicit full-body copies.
/// Retain the owner for as long as its chunks are used; independently retained
/// or transformed Data must be charged to a separate downstream budget.
public final class BufferedBody: Sendable {
    public let chunks: [Data]
    public let byteCount: Int
    private let budget: BodyBufferBudget

    init(chunks: [Data], byteCount: Int, budget: BodyBufferBudget) {
        self.chunks = chunks
        self.byteCount = byteCount
        self.budget = budget
    }

    deinit { budget.release(byteCount) }
}

public enum PreparedBody: Sendable {
    /// Not read, parsed, decoded or copied by the execution core.
    case streaming(any BodyReader)
    case buffered(BufferedBody)
}

enum BodyCollector {
    @concurrent
    static func collect(
        from reader: any BodyReader,
        limits: ExecutionLimits,
        budget: BodyBufferBudget
    ) async throws -> BufferedBody {
        var chunks: [Data] = []
        var retainedBytes = 0
        var transferred = false
        defer {
            if !transferred { budget.release(retainedBytes) }
        }

        while true {
            try Task.checkCancellation()
            // One extra byte lets us distinguish an exactly-full body from an
            // oversized body without trusting Content-Length.
            let allowance = min(limits.readChunkBytes, limits.maximumBodyBytes - retainedBytes + 1)
            try budget.reserve(allowance)
            let chunk: Data?
            do {
                chunk = try await reader.read(maximumBytes: allowance)
                try Task.checkCancellation()
            } catch {
                budget.release(allowance)
                throw error
            }
            guard let chunk else {
                budget.release(allowance)
                transferred = true
                return BufferedBody(chunks: chunks, byteCount: retainedBytes, budget: budget)
            }
            guard !chunk.isEmpty, chunk.count <= allowance else {
                budget.release(allowance)
                throw ExecutionResourceError.oversizedChunk
            }
            guard chunk.count <= limits.maximumBodyBytes - retainedBytes else {
                budget.release(allowance)
                throw ExecutionResourceError.bodyTooLarge
            }
            budget.release(allowance - chunk.count)
            retainedBytes += chunk.count
            // Coalesce tiny transport chunks so metadata cannot grow by one
            // Data allocation per byte of payload.
            if !chunks.isEmpty, chunks[chunks.count - 1].count < limits.readChunkBytes {
                let fill = min(limits.readChunkBytes - chunks[chunks.count - 1].count, chunk.count)
                chunks[chunks.count - 1].append(chunk.prefix(fill))
                if fill < chunk.count { chunks.append(Data(chunk.dropFirst(fill))) }
            } else {
                chunks.append(chunk)
            }
        }
    }
}
