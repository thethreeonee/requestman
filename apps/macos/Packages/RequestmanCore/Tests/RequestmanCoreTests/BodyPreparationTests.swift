import Foundation
import Testing
@testable import RequestmanCore

@Test func headerOnlyAndUnmatchedPlansNeverReadBodies() async throws {
    let runtime = try FlowExecutionRuntime(limits: smallLimits())
    let request = ChunkReader("request data that must not be read")
    let response = ChunkReader("response data that must not be read")
    try await runtime.execute(plan: executionPlan(request: [.metadataOnly])) { context in
        guard case .streaming = try await context.prepareBody(request, for: .request),
              case .streaming = try await context.prepareBody(response, for: .response) else {
            Issue.record("Metadata-only plans must preserve the streaming path")
            return
        }
    }
    #expect(await request.calls == 0)
    #expect(await response.calls == 0)
}

@Test func responseBodyRequirementDoesNotBufferRequest() async throws {
    let runtime = try FlowExecutionRuntime(limits: smallLimits())
    let request = ChunkReader("request")
    let response = ChunkReader("abcdefgh", chunkSize: 1)
    try await runtime.execute(plan: executionPlan(response: [.completeBody])) { context in
        _ = try await context.prepareBody(request, for: .request)
        guard case let .buffered(body) = try await context.prepareBody(response, for: .response) else {
            Issue.record("Response must be buffered")
            return
        }
        #expect(body.chunks == [Data("abcd".utf8), Data("efgh".utf8)])
        #expect(body.byteCount == 8)
        await #expect(throws: ExecutionResourceError.bodyAlreadyPrepared) {
            try await context.prepareBody(response, for: .response)
        }
    }
    #expect(await request.calls == 0)
}

@Test func completeBodiesCanExceedFormerSizeLimitsAndRemainShared() async throws {
    let runtime = try FlowExecutionRuntime(limits: ExecutionLimits(readChunkBytes: 65_536))
    let payload = String(repeating: "x", count: 5 * 1_048_576)
    let first = try await runtime.execute(plan: executionPlan(request: [.completeBody])) { context in
        try await context.prepareBody(ChunkReader(payload, chunkSize: 65_536), for: .request)
    }
    let second = try await runtime.execute(plan: executionPlan(response: [.completeBody])) { context in
        try await context.prepareBody(ChunkReader(payload, chunkSize: 65_536), for: .response)
    }
    for prepared in [first, second] {
        guard case let .buffered(body) = prepared else { Issue.record("Expected buffered body"); return }
        #expect(body.byteCount == payload.utf8.count)
        #expect(body.chunks.reduce(into: Data()) { $0.append($1) } == Data(payload.utf8))
    }
}

private struct InvalidChunkReader: BodyReader {
    let empty: Bool
    func read(maximumBytes: Int) async throws -> Data? {
        empty ? Data() : Data(repeating: 0, count: maximumBytes + 1)
    }
}

@Test(arguments: [true, false])
func invalidReaderChunksCannotCreateAnUnboundedLoop(empty: Bool) async throws {
    let runtime = try FlowExecutionRuntime(limits: smallLimits())
    await #expect(throws: ExecutionResourceError.oversizedChunk) {
        try await runtime.execute(plan: executionPlan(request: [.completeBody])) { context in
            _ = try await context.prepareBody(InvalidChunkReader(empty: empty), for: .request)
        }
    }
}

private struct SuspendedReader: BodyReader {
    let entered: TestLatch
    let stream: AsyncStream<Data>

    func read(maximumBytes: Int) async throws -> Data? {
        await entered.open()
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }
}

@Test func cancellingBodyReadReleasesAdmission() async throws {
    let runtime = try FlowExecutionRuntime(limits: smallLimits())
    let entered = TestLatch()
    let pair = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(1))
    let reader = SuspendedReader(entered: entered, stream: pair.stream)
    let task = Task {
        try await runtime.execute(plan: executionPlan(request: [.completeBody])) { context in
            try await context.prepareBody(reader, for: .request)
        }
    }
    await entered.wait()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    pair.continuation.finish()
    #expect(runtime.admission.active == 0)
}
