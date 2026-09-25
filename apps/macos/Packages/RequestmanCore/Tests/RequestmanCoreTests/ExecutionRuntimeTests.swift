import Foundation
import Testing
@testable import RequestmanCore

@Test func fullAdmissionQueueRejectsWithoutExecutingWork() async throws {
    let gate = try BoundedExecutionGate(maximumActive: 1, maximumWaiting: 1)
    let release = TestLatch()
    let active = Task { try await gate.run { await release.wait(); return 1 } }
    try await waitForAdmission(gate, active: 1, waiting: 0)
    let queued = Task { try await gate.run { 2 } }
    try await waitForAdmission(gate, active: 1, waiting: 1)
    await #expect(throws: ExecutionResourceError.queueFull) {
        try await gate.run { Issue.record("Rejected work ran") }
    }
    await release.open()
    #expect(try await active.value == 1)
    #expect(try await queued.value == 2)
    #expect(gate.snapshot == .init(active: 0, waiting: 0))
}

@Test func cancellingAWaiterDoesNotReleaseAnActivePermit() async throws {
    let gate = try BoundedExecutionGate(maximumActive: 1, maximumWaiting: 1)
    let release = TestLatch()
    let active = Task { try await gate.run { await release.wait() } }
    try await waitForAdmission(gate, active: 1, waiting: 0)
    let queued = Task { try await gate.run { Issue.record("Cancelled work ran") } }
    try await waitForAdmission(gate, active: 1, waiting: 1)
    queued.cancel()
    await #expect(throws: CancellationError.self) { try await queued.value }
    #expect(gate.snapshot == .init(active: 1, waiting: 0))
    await release.open()
    try await active.value
    #expect(gate.snapshot == .init(active: 0, waiting: 0))
}

@Test func admissionIsFIFO() async throws {
    let gate = try BoundedExecutionGate(maximumActive: 1, maximumWaiting: 2)
    let releaseFirst = TestLatch()
    let releaseSecond = TestLatch()
    let first = Task { try await gate.run { await releaseFirst.wait() } }
    try await waitForAdmission(gate, active: 1, waiting: 0)
    let second = Task { try await gate.run { await releaseSecond.wait(); return 2 } }
    try await waitForAdmission(gate, active: 1, waiting: 1)
    let third = Task { try await gate.run { 3 } }
    try await waitForAdmission(gate, active: 1, waiting: 2)
    await releaseFirst.open()
    try await first.value
    try await waitForAdmission(gate, active: 1, waiting: 1)
    await releaseSecond.open()
    #expect(try await second.value == 2)
    #expect(try await third.value == 3)
}

@Test func expiredDeadlineNeverRunsOperation() async throws {
    let runtime = try FlowExecutionRuntime(limits: smallLimits())
    await #expect(throws: ExecutionResourceError.timedOut) {
        try await runtime.execute(plan: executionPlan(), deadline: .now.advanced(by: .seconds(-1))) { _ in
            Issue.record("Expired work ran")
        }
    }
    #expect(runtime.admission == .init(active: 0, waiting: 0))
    #expect(runtime.events.drain().events.map(\.kind) == [.submitted, .timedOut])
}

@Test func deadlineIncludesTimeSpentWaitingForAdmission() async throws {
    let runtime = try FlowExecutionRuntime(limits: smallLimits(maximumActive: 1, maximumWaiting: 1))
    let release = TestLatch()
    let active = Task { try await runtime.execute(plan: executionPlan()) { _ in await release.wait() } }
    try await waitForAdmission(runtime, active: 1, waiting: 0)
    await #expect(throws: ExecutionResourceError.timedOut) {
        try await runtime.execute(plan: executionPlan(), deadline: .now.advanced(by: .milliseconds(20))) { _ in
            Issue.record("Queued work must not start after its deadline")
        }
    }
    #expect(runtime.admission == .init(active: 1, waiting: 0))
    await release.open()
    try await active.value
    #expect(runtime.events.drain().events.contains { $0.kind == .timedOut })
}

@Test func finishedContextCannotStartAnotherBodyRead() async throws {
    let runtime = try FlowExecutionRuntime(limits: smallLimits())
    let context = try await runtime.execute(plan: executionPlan(request: [.completeBody])) { $0 }
    let reader = ChunkReader("abc")
    await #expect(throws: ExecutionResourceError.executionFinished) {
        try await context.prepareBody(reader, for: .request)
    }
    #expect(await reader.calls == 0)
    #expect(runtime.bodyBudget.reservedBytes == 0)
}

@Test func cancellationWhileQueuedReleasesRuntimeWaiter() async throws {
    let runtime = try FlowExecutionRuntime(limits: smallLimits(maximumActive: 1, maximumWaiting: 1))
    let release = TestLatch()
    let active = Task { try await runtime.execute(plan: executionPlan()) { _ in await release.wait() } }
    try await waitForAdmission(runtime, active: 1, waiting: 0)
    let queued = Task {
        try await runtime.execute(plan: executionPlan()) { _ in Issue.record("Cancelled operation ran") }
    }
    try await waitForAdmission(runtime, active: 1, waiting: 1)
    queued.cancel()
    await #expect(throws: CancellationError.self) { try await queued.value }
    #expect(runtime.admission == .init(active: 1, waiting: 0))
    await release.open()
    try await active.value
    #expect(runtime.events.drain().events.contains { $0.kind == .cancelled })
}

private enum TestFailure: Error { case expected }

@Test func operationFailureDoesNotLeakPermit() async throws {
    let runtime = try FlowExecutionRuntime(limits: smallLimits(maximumActive: 1, maximumWaiting: 0))
    await #expect(throws: TestFailure.expected) {
        try await runtime.execute(plan: executionPlan()) { _ in throw TestFailure.expected }
    }
    #expect(try await runtime.execute(plan: executionPlan()) { _ in 42 } == 42)
    #expect(runtime.admission.active == 0)
}

@Test func environmentChangesDoNotMutatePreparedPlans() async throws {
    var values = ["apiKey": "dev-key"]
    let environment = EnvironmentSnapshot(name: "dev", values: values)
    let plan = FlowExecutionPlan(environment: environment, requestInputs: [], responseInputs: [.completeBody])
    values["apiKey"] = "staging-key"
    let runtime = try FlowExecutionRuntime(limits: smallLimits())
    let result = try await runtime.execute(plan: plan) { context in context.plan.environment.values["apiKey"] }
    #expect(result == "dev-key")
    #expect(plan.requestBodyMode == .streaming)
    #expect(plan.responseBodyMode == .buffered)
}

@Test func slowRecordConsumerCannotBlockExecution() async throws {
    let runtime = try FlowExecutionRuntime(limits: smallLimits())
    for index in 0..<100 {
        #expect(try await runtime.execute(plan: executionPlan()) { _ in index } == index)
    }
    #expect(runtime.events.pendingCount == 16)
    let batch = runtime.events.drain()
    #expect(batch.events.count == 8)
    #expect(batch.droppedEvents == 300 - 16)
    #expect(runtime.admission == .init(active: 0, waiting: 0))
}

@Test func eventRingPreservesOrderAcrossWrapAndBatchDrain() throws {
    let events = try ExecutionEventBuffer(capacity: 3, maximumBatch: 2)
    let version = UUID()
    let ids = (0..<5).map { _ in UUID() }
    for id in ids { events.append(.init(executionID: id, planVersion: version, kind: .completed)) }
    let first = events.drain()
    #expect(first.events.map(\.executionID) == Array(ids[2...3]))
    #expect(first.droppedEvents == 2)
    let second = events.drain()
    #expect(second.events.map(\.executionID) == [ids[4]])
    #expect(second.droppedEvents == 0)
    #expect(events.pendingCount == 0)
}

@Test func limitsRejectInvalidConfigurations() {
    #expect(throws: ExecutionResourceError.invalidLimits) { try ExecutionLimits(maximumActive: 0) }
    #expect(throws: ExecutionResourceError.invalidLimits) { try ExecutionLimits(maximumWaiting: -1) }
    #expect(throws: ExecutionResourceError.invalidLimits) { try ExecutionLimits(maximumBodyBytes: Int.max) }
    #expect(throws: ExecutionResourceError.invalidLimits) { try ExecutionLimits(timeout: .zero) }
    #expect(throws: ExecutionResourceError.invalidLimits) { try ExecutionEventBuffer(capacity: 1, maximumBatch: 2) }
}
