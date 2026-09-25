import Foundation
import Testing
@testable import RequestmanCore

actor TestLatch {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

actor ChunkReader: BodyReader {
    let data: Data
    let chunkSize: Int
    var offset = 0
    var calls = 0

    init(_ text: String, chunkSize: Int = .max) {
        data = Data(text.utf8)
        self.chunkSize = chunkSize
    }

    func read(maximumBytes: Int) async throws -> Data? {
        calls += 1
        guard offset < data.count else { return nil }
        let end = min(data.count, offset + min(maximumBytes, chunkSize))
        defer { offset = end }
        return data.subdata(in: offset..<end)
    }
}

func smallLimits(
    maximumActive: Int = 2,
    maximumWaiting: Int = 2
) throws -> ExecutionLimits {
    try ExecutionLimits(
        maximumActive: maximumActive, maximumWaiting: maximumWaiting,
        readChunkBytes: 4, eventCapacity: 16, maximumEventBatch: 8
    )
}

func executionPlan(
    request: [StepInputRequirement] = [],
    response: [StepInputRequirement] = []
) -> FlowExecutionPlan {
    FlowExecutionPlan(
        environment: EnvironmentSnapshot(name: "dev", values: ["apiKey": "example"]),
        requestInputs: request, responseInputs: response
    )
}

/// Observe admission rather than relying on arbitrary sleeps or scheduler order.
func waitForAdmission(_ gate: BoundedExecutionGate, active: Int, waiting: Int) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while gate.snapshot != .init(active: active, waiting: waiting) {
        try #require(ContinuousClock.now < deadline, "Admission state never reached")
        await Task.yield()
    }
}

func waitForAdmission(_ runtime: FlowExecutionRuntime, active: Int, waiting: Int) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while runtime.admission != .init(active: active, waiting: waiting) {
        try #require(ContinuousClock.now < deadline, "Runtime admission state never reached")
        await Task.yield()
    }
}
