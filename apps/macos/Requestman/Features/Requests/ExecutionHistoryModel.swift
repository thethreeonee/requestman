import Foundation
import Observation
import RequestmanCore

@MainActor @Observable
final class ExecutionHistoryModel {
    private(set) var displayGeneration = 0
    private var liveRecords: [CaptureRecord] = []
    private var openedRecords: [CaptureRecord]?
    private(set) var openedFileName: String?
    private var liveSelection: UUID?
    private var liveFilter = CaptureRecordFilter()
    var isViewingFile: Bool { openedRecords != nil }
    var records: [CaptureRecord] { openedRecords ?? liveRecords }
    /// Export obeys the actual filter, excluding temporary reveal exceptions used by replay navigation.
    var recordsForSaving: [CaptureRecord] { records.filter { filter.matches($0) } }
    func openLog(_ records: [CaptureRecord], name: String) {
        if !isViewingFile { liveSelection = selectedID; liveFilter = filter }
        displayGeneration += 1
        openedRecords = records; openedFileName = name
        filter = CaptureRecordFilter(); revealedID = nil; selectedID = records.first?.id
    }
    func returnToLive() {
        guard isViewingFile else { return }
        displayGeneration += 1
        openedRecords = nil; openedFileName = nil
        filter = liveFilter; revealedID = nil
        selectedID = liveRecords.contains { $0.id == liveSelection } ? liveSelection : nil
        liveSelection = nil
    }
    private(set) var dropped = 0
    var paused = false
    var selectedID: UUID?
    var filter = CaptureRecordFilter() { didSet { if filter != oldValue { revealedID = nil } } }
    private var revealedID: UUID?
    private var latestReplayID: UUID?
    var latestReplay: CaptureRecord? { isViewingFile ? nil : liveRecords.first { $0.id == latestReplayID } }
    func reveal(_ id: UUID) {
        guard records.contains(where: { $0.id == id }) else { return }
        revealedID = id; selectedID = id
    }
    func beginReplay(_ draft: RequestReplayDraft) {
        returnToLive()
        var record = CaptureRecord(id: draft.id, method: draft.method, url: draft.url)
        record.deviceSource = "local"
        record.replayID = draft.id; record.replaySourceID = draft.sourceRecordID
        record.connectionState = .connecting
        append([record], dropped: 0)
        latestReplayID = record.id
        reveal(record.id)
    }
    func failReplaySubmission(_ id: UUID, error: Error, cancelled: Bool) {
        guard var record = liveRecords.first(where: { $0.id == id }), record.connectionState.isActive else { return }
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
            if let index = liveRecords.firstIndex(where: { $0.id == record.id }) { liveRecords[index] = record }
            else { liveRecords.insert(record, at: 0) }
        }
        while liveRecords.count > 500 {
            guard let index = liveRecords.lastIndex(where: { $0.id != latestReplayID && !($0.replayID != nil && $0.connectionState.isActive) }) else { break }
            liveRecords.remove(at: index)
        }
        if !isViewingFile, let selectedID, !liveRecords.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
    }
    func clear() {
        returnToLive()
        liveRecords.removeAll(); selectedID = nil; revealedID = nil; latestReplayID = nil; dropped = 0
    }
    var filtered: [CaptureRecord] { records.filter { $0.id == revealedID || filter.matches($0) } }
    var selected: CaptureRecord? { records.first { $0.id == selectedID } }
}
