import AppKit
import RequestmanCore

@MainActor
final class RequestsViewController: ObservedViewController {
    private let model: WorkspaceModel
    private let filters = RequestFilterControls()
    private let table = RequestRecordsTable()
    private let status = NativeUI.label("", size: 11, secondary: true)
    private let empty = RequestEmptyStateView()
    init(model: WorkspaceModel) { self.model = model; super.init() }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        view = FlippedView()
        filters.onFilterChange = { [weak model] in model?.history.filter = $0 }
        filters.toggleRecording = { [weak model] in guard let model else { return }; model.setRecordingPaused(!model.history.paused) }
        filters.clear = { [weak model] in model?.clearHistory() }
        table.onSelectionChange = { [weak model] in model?.history.selectedID = $0 }
        table.onModifyRequest = { [weak model] in model?.addWorkflow(matchingURL: $0) }
        let separator = NSBox(); separator.boxType = .separator
        let tableContainer = NSView()
        NativeUI.pin(table, to: tableContainer)
        empty.translatesAutoresizingMaskIntoConstraints = false; tableContainer.addSubview(empty)
        NSLayoutConstraint.activate([empty.centerXAnchor.constraint(equalTo: tableContainer.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: tableContainer.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: tableContainer.widthAnchor, constant: -40)])
        let stack = NativeUI.stack([filters, status, separator, tableContainer], spacing: 0)
        NativeUI.pin(stack, to: view)
        for child in [filters, separator, tableContainer] { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        tableContainer.setContentHuggingPriority(.defaultLow, for: .vertical)
    }
    func focusList() { table.focusList() }
    func showFilters() { filters.showFilters() }
    override func viewWillAppear() { super.viewWillAppear(); model.history.selectedID = nil }
    override func refresh() {
        let history = model.history, records = model.history.filtered
        filters.update(filter: history.filter, records: history.records, paused: history.paused)
        status.stringValue = [history.paused ? "记录已暂停，代理继续工作" : "", history.dropped > 0 ? "高负载下已丢弃 \(history.dropped) 条待显示记录" : ""].filter { !$0.isEmpty }.joined(separator: "    ")
        status.isHidden = status.stringValue.isEmpty
        table.update(records: records, selectedID: history.selectedID)
        empty.isHidden = !records.isEmpty
        empty.update(title: history.records.isEmpty ? "等待请求" : "没有符合条件的记录", description: history.records.isEmpty ? "启动捕获，将浏览器连接到本地代理后，请求会显示在这里。" : "调整搜索或筛选条件。", symbol: "clock")
    }
}
