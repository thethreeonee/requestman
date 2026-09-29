import Foundation
import RequestmanCore

@main
struct RequestFilterPersistenceChecks {
    @MainActor static func main() throws {
        let suite = "RequestFilterPersistenceChecks.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = ExecutionHistoryModel(filterDefaults: defaults)
        precondition(!history.savesFilter && history.filter == CaptureRecordFilter())
        history.filter.search = "orders"
        precondition(RequestLogFilterPreferences.load(from: defaults) == nil)
        history.savesFilter = true
        precondition(RequestLogFilterPreferences.load(from: defaults) == history.filter)
        history.filter.resource = .json
        history.filter.conditionGroup = .init(conditions: [.init(field: .method, value: "POST")])
        history.filter.inverted = true
        let saved = history.filter
        let restarted = ExecutionHistoryModel(filterDefaults: defaults)
        precondition(restarted.savesFilter && restarted.filter == saved)
        history.clear()
        precondition(history.filter == saved)
        history.openLog([], name: "test")
        precondition(history.filter == CaptureRecordFilter())
        precondition(RequestLogFilterPreferences.load(from: defaults) == saved)
        history.returnToLive()
        precondition(history.filter == saved)
        history.openLog([], name: "test")
        history.filter.search = "file search"
        let fileFilter = history.filter
        precondition(RequestLogFilterPreferences.load(from: defaults) == fileFilter)
        history.returnToLive()
        precondition(history.filter == saved)
        precondition(RequestLogFilterPreferences.load(from: defaults) == fileFilter)
        history.savesFilter = false
        precondition(history.filter == saved)
        history.filter.search = "temporary"
        let disabled = ExecutionHistoryModel(filterDefaults: defaults)
        precondition(!disabled.savesFilter && disabled.filter == CaptureRecordFilter())
        history.savesFilter = true
        history.filter = CaptureRecordFilter()
        let reset = ExecutionHistoryModel(filterDefaults: defaults)
        precondition(reset.savesFilter && reset.filter == CaptureRecordFilter())
        print("Filter persistence model checks passed (no UI created or run)")
    }
}
