import Foundation

/// Pull-based transport boundary. Readers must honor the chunk limit, propagate
/// task cancellation, and not prefetch into an unbounded queue. Nil means EOF;
/// a returned chunk must be nonempty. Supply decoded bytes when editing a body.
public protocol BodyReader: Sendable {
    func read(maximumBytes: Int) async throws -> Data?
}

/// Share this owner between original/current views without implicit full-body copies.
public final class BufferedBody: Sendable {
    public let chunks: [Data]
    public let byteCount: Int
    init(chunks: [Data], byteCount: Int) {
        self.chunks = chunks
        self.byteCount = byteCount
    }
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
        limits: ExecutionLimits
    ) async throws -> BufferedBody {
        var chunks: [Data] = []
        var retainedBytes = 0
        while true {
            try Task.checkCancellation()
            let chunk = try await reader.read(maximumBytes: limits.readChunkBytes)
            try Task.checkCancellation()
            guard let chunk else {
                return BufferedBody(chunks: chunks, byteCount: retainedBytes)
            }
            guard !chunk.isEmpty, chunk.count <= limits.readChunkBytes else {
                throw ExecutionResourceError.oversizedChunk
            }
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
