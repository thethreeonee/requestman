import Foundation
import RequestmanCore
import os

/// Receives background traces even after the transport event loop has stopped.
/// Terminal snapshots and late updates use one lock and retain the capture generation.
final class TransactionTraceRecorder: Sendable {
    private struct State {
        var trace: [StepExecutionTrace] = []
        var terminal: CaptureRecord?
        var acceptsLateTrace = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let records: CaptureRecordBuffer
    private let generation: UInt64
    private let workflowName: String

    init(records: CaptureRecordBuffer, generation: UInt64, workflowName: String) {
        self.records = records
        self.generation = generation
        self.workflowName = workflowName
    }

    func append(_ trace: StepExecutionTrace) {
        state.withLock { state in
            guard state.terminal == nil || state.acceptsLateTrace else { return }
            state.trace.append(trace)
            if var record = state.terminal {
                merge(state.trace, into: &record)
                record.revision &+= 1
                state.terminal = record
                // CaptureRecordBuffer never calls this recorder, so lock ordering is one-way.
                records.append(record, generation: generation)
            }
        }
    }

    func publishFinal(_ snapshot: CaptureRecord, acceptsLateTrace: Bool) {
        state.withLock { state in
            guard state.terminal == nil else { return }
            var record = snapshot
            merge(state.trace, into: &record)
            state.terminal = record
            state.acceptsLateTrace = acceptsLateTrace
            records.append(record, generation: generation)
        }
    }

    private func merge(_ trace: [StepExecutionTrace], into record: inout CaptureRecord) {
        record.executionTrace = trace
        let applied = trace.filter { $0.status == .applied }
        record.steps = applied.map { $0.kind.title }
        if record.outcome == .forwarded && !applied.isEmpty { record.outcome = .modified }
        record.matchedRules = applied.map {
            CaptureMatchedRule(kind: $0.kind, name: workflowName, response: $0.phase == .response)
        }
    }
}
