import Foundation
import Testing
@testable import RequestmanCore
@testable import RequestmanProxy

struct TransactionTraceRecorderTests {
    @Test func lateCancellationCompletesTraceWithoutDuplicatingAppliedSteps() throws {
        let records = CaptureRecordBuffer()
        let recorder = TransactionTraceRecorder(records: records, generation: records.generation, workflowName: "test")
        let header = trace(.setHeader, status: .applied)
        recorder.append(header)
        var terminal = CaptureRecord(method: "GET", url: "http://example.test/")
        terminal.connectionState = .failed; terminal.error = "捕获已停止"
        terminal.revision = 3
        recorder.publishFinal(terminal, acceptsLateTrace: true)
        let first = try #require(records.drain().records.first)
        #expect(first.executionTrace.map(\.stepID) == [header.stepID])
        recorder.append(trace(.delay, status: .cancelled))
        let late = try #require(records.drain().records.first)
        #expect(late.executionTrace.map(\.status) == [.applied, .cancelled])
        #expect(late.steps == [ModificationKind.setHeader.title])
        #expect(late.matchedRules.count == 1)
        #expect(late.revision == 4)
        #expect(late.error == terminal.error)
    }

    @Test func clearRejectsLateTraceAndSuccessfulFinalizationStaysFinal() throws {
        let records = CaptureRecordBuffer()
        let recorder = TransactionTraceRecorder(records: records, generation: records.generation, workflowName: "test")
        var terminal = CaptureRecord(method: "GET", url: "http://example.test/")
        terminal.connectionState = .closed
        recorder.publishFinal(terminal, acceptsLateTrace: false)
        _ = records.drain()
        recorder.append(trace(.delay, status: .cancelled))
        #expect(records.drain().records.isEmpty)

        let pending = TransactionTraceRecorder(records: records, generation: records.generation, workflowName: "test")
        pending.publishFinal(terminal, acceptsLateTrace: true)
        records.clear()
        pending.append(trace(.delay, status: .cancelled))
        #expect(records.drain().records.isEmpty)
    }

    private func trace(_ kind: ModificationKind, status: StepExecutionTrace.Status) -> StepExecutionTrace {
        StepExecutionTrace(stepID: UUID(), kind: kind, phase: .response, elapsed: .milliseconds(1),
            status: status, error: status == .cancelled ? "cancelled" : nil)
    }
}
