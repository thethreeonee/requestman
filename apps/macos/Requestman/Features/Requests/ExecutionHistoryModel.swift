import Foundation
import Observation
import RequestmanCore

@MainActor @Observable
final class ExecutionHistoryModel {
    private(set) var records: [CaptureRecord] = []
    private(set) var dropped = 0
    var paused = false
    var selectedID: UUID?
    var filter = CaptureRecordFilter() { didSet { if filter != oldValue { revealedID = nil } } }
    private var revealedID: UUID?
    private var latestReplayID: UUID?
    var latestReplay: CaptureRecord? { records.first { $0.id == latestReplayID } }
    func reveal(_ id: UUID) {
        guard records.contains(where: { $0.id == id }) else { return }
        revealedID = id; selectedID = id
    }
    func beginReplay(_ draft: RequestReplayDraft) {
        var record = CaptureRecord(id: draft.id, method: draft.method, url: draft.url)
        record.replayID = draft.id; record.replaySourceID = draft.sourceRecordID
        record.connectionState = .connecting
        append([record], dropped: 0)
        latestReplayID = record.id
        reveal(record.id)
    }
    func failReplaySubmission(_ id: UUID, error: Error, cancelled: Bool) {
        guard var record = records.first(where: { $0.id == id }), record.connectionState.isActive else { return }
        record.connectionState = cancelled ? .closed : .failed
        record.replayCancelled = cancelled
        record.error = cancelled ? nil : error.localizedDescription
        record.outcome = cancelled ? .forwarded : .failed
        append([record], dropped: 0)
    }
    func append(_ batch: [CaptureRecord], dropped: Int) {
        guard !batch.isEmpty || dropped > 0 else { return }
        self.dropped += dropped
        for record in batch {
            if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record }
            else { records.insert(record, at: 0) }
        }
        while records.count > 500 {
            // Keep cancellable replays and the latest result reachable during busy capture.
            guard let index = records.lastIndex(where: { $0.id != latestReplayID && !($0.replayID != nil && $0.connectionState.isActive) }) else { break }
            records.remove(at: index)
        }
        if let selectedID, !records.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
    }
    func clear() { records.removeAll(); selectedID = nil; revealedID = nil; latestReplayID = nil; dropped = 0 }
    var filtered: [CaptureRecord] { records.filter { $0.id == revealedID || filter.matches($0) } }
    var selected: CaptureRecord? { records.first { $0.id == selectedID } }
}
