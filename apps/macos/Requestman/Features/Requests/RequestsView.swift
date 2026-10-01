import AppKit
import RequestmanCore

@MainActor
final class RequestsViewController: ObservedViewController {
    var minimumContentWidth: CGFloat { filters.minimumContentWidth }
    private let model: WorkspaceModel
    private let filters = RequestFilterControls()
    private let table = RequestRecordsTable()
    private var displayOptions: RequestLogDisplayOptions {
        get { model.history.displayOptions }
        set { model.history.displayOptions = newValue }
    }
    private let status = NativeUI.label("", size: 11, secondary: true)
    private let replayStatus = NativeUI.label("", size: 12)
    private lazy var showReplay = ActionButton(title: "查看重放结果") { [weak self] in
        guard let self, let record = model.history.latestReplay else { return }
        model.history.reveal(record.id)
    }
    private lazy var cancelReplay = ActionButton(title: "取消此次重放") { [weak self] in
        guard let self, let id = model.history.latestReplay?.replayID else { return }
        model.cancelReplay(id)
    }
    private lazy var replayBar = NativeUI.stack([replayStatus, showReplay, cancelReplay], vertical: false, spacing: 8)
    private let fileName = NativeUI.label("", size: 12)
    private lazy var returnToLive = ActionButton(title: "返回实时日志") { [weak model] in model?.history.returnToLive() }
    private lazy var fileBar = NativeUI.stack([fileName, returnToLive], vertical: false, spacing: 8)
    private let empty = RequestEmptyStateView()
    private var filterAccessory: NSViewController?
    private weak var filterAccessoryItem: NSSplitViewItem?
    init(model: WorkspaceModel) {
        self.model = model; super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(restoreDisplayOptions),
                                               name: WorkspaceTransfer.preferencesRestored, object: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        view = FlippedView()
        filters.onSaveFilterChange = { [weak model] in model?.history.savesFilter = $0 }
        filters.onFilterChange = { [weak model] in model?.history.filter = $0 }
        filters.toggleRecording = { [weak model] in guard let model else { return }; model.setRecordingPaused(!model.history.paused) }
        filters.clear = { [weak model] in model?.clearHistory() }
        filters.showDisplayOptions = { [weak self] in self?.showDisplayOptions(relativeTo: $0) }
        table.onColumnOrderChange = { [weak self] order in
            guard let self else { return }
            displayOptions.columnOrder = order
            displayOptions.save()
        }
        table.onDeviceAliasChange = { [weak model] source, alias in model?.document.deviceAliases[source] = alias.isEmpty ? nil : alias }
        table.onSelectionChange = { [weak model] in model?.history.selectedID = $0 }
        table.replayUnavailableReason = { [weak model] in model?.replayUnavailableReason }
        table.onReplay = { [weak self] record, editing in
            guard let self else { return }
            model.replay(record, editing: editing, presenter: self)
        }
        table.onCancelReplay = { [weak model] in model?.cancelReplay($0) }
        table.sourceExists = { [weak model] id in model?.history.records.contains { $0.id == id } ?? false }
        table.revealSource = { [weak model] in model?.history.reveal($0) }
        replayStatus.lineBreakMode = .byTruncatingMiddle
        replayStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        replayBar.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        fileName.lineBreakMode = .byTruncatingMiddle
        fileName.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fileBar.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        table.onSaveSession = { [weak self] record in RequestLogTransfer.save(records: [record], window: self?.view.window) }
        table.onMockRequest = { [weak model] in model?.addMockWorkflow(from: $0) }
        let tableContainer = NSView()
        NativeUI.pin(table, to: tableContainer)
        empty.translatesAutoresizingMaskIntoConstraints = false; tableContainer.addSubview(empty)
        NSLayoutConstraint.activate([empty.centerXAnchor.constraint(equalTo: tableContainer.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: tableContainer.safeAreaLayoutGuide.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: tableContainer.widthAnchor, constant: -40)])
        if #available(macOS 26.0, *) {
            NativeUI.pin(tableContainer, to: view)
        } else {
            let separator = NSBox(); separator.boxType = .separator
            let stack = NativeUI.stack([fileBar, filters, status, replayBar, separator, tableContainer], spacing: 0)
            NativeUI.pin(stack, to: view)
            for child in [fileBar, filters, replayBar, separator, tableContainer] { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
            tableContainer.setContentHuggingPriority(.defaultLow, for: .vertical)
        }
    }
    func installFilterAccessory(on item: NSSplitViewItem, visible: Bool) {
        guard #available(macOS 26.0, *), filterAccessory == nil else { return }
        _ = view
        let accessory = NSSplitViewItemAccessoryViewController()
        accessory.automaticallyAppliesContentInsets = false
        if #available(macOS 26.1, *) { accessory.preferredScrollEdgeEffectStyle = .soft }
        let bar = NativeUI.stack([fileBar, filters, status, replayBar], spacing: 0)
        fileBar.widthAnchor.constraint(equalTo: bar.widthAnchor).isActive = true
        filters.widthAnchor.constraint(equalTo: bar.widthAnchor).isActive = true
        replayBar.widthAnchor.constraint(equalTo: bar.widthAnchor).isActive = true
        bar.setContentHuggingPriority(.required, for: .vertical)
        accessory.view = bar
        filterAccessory = accessory
        filterAccessoryItem = item
        setFilterAccessoryVisible(visible)
    }
    func setFilterAccessoryVisible(_ visible: Bool) {
        if #available(macOS 26.0, *), let accessory = filterAccessory as? NSSplitViewItemAccessoryViewController,
           let item = filterAccessoryItem {
            // isHidden only collapses the accessory; its controls remain in the window.
            // Detach it from the shared pane when showing request modification.
            let index = item.topAlignedAccessoryViewControllers.firstIndex { $0 === accessory }
            if visible, index == nil {
                item.addTopAlignedAccessoryViewController(accessory)
            } else if !visible, let index {
                item.removeTopAlignedAccessoryViewController(at: index)
            }
            accessory.isHidden = !visible
        }
    }
    func focusList() { table.focusList() }
    func showFilters() { filters.showFilters() }
    private func showDisplayOptions(relativeTo anchor: NSView) {
        guard let window = anchor.window, window.attachedSheet == nil else { return }
        let workflowNames = Dictionary(model.document.projects.flatMap(\.workflows).map { ($0.id, $0.name) },
                                       uniquingKeysWith: { first, _ in first })
        presentAsSheet(RequestLogDisplayOptionsEditor(options: displayOptions,
            allowLAN: model.document.proxy.allowLAN, records: model.history.records,
            workflowNames: workflowNames, deviceAliases: model.document.deviceAliases) { [weak self] edited in
            guard let self else { return }
            displayOptions = edited
            displayOptions.save()
            refresh()
        })
    }
    @objc private func restoreDisplayOptions() {
        displayOptions = .load()
        if isViewLoaded { refresh() }
    }
    override func refresh() {
        let history = model.history, records = model.history.filtered
        fileBar.isHidden = !history.isViewingFile
        fileName.stringValue = history.openedFileName.map { "日志文件：" + $0 } ?? ""
        fileName.toolTip = fileName.stringValue
        let replay = history.latestReplay
        replayBar.isHidden = replay == nil
        replayStatus.stringValue = replay.map { ($0.replaySummary ?? "") + " · " + $0.method + " " + $0.url } ?? ""
        replayStatus.toolTip = replayStatus.stringValue
        cancelReplay.isHidden = replay?.connectionState.isActive != true
        filters.update(filter: history.filter, records: history.records, paused: history.paused,
                       viewingFile: history.isViewingFile, customColumnCount: displayOptions.explicitLayout == nil ? 0 : displayOptions.layoutColumns.count,
                       savesFilter: history.savesFilter)
        status.stringValue = [history.paused ? "记录已暂停，代理继续工作；手动重放仍记录结果" : "", history.dropped > 0 ? "高负载下已丢弃 \(history.dropped) 条待显示记录" : ""].filter { !$0.isEmpty }.joined(separator: "    ")
        status.isHidden = history.isViewingFile || status.stringValue.isEmpty
        let workflowNames = Dictionary(model.document.projects.flatMap(\.workflows).map { ($0.id, $0.name) },
                                       uniquingKeysWith: { first, _ in first })
        table.update(records: records, selectedID: history.selectedID, workflowNames: workflowNames,
                     deviceAliases: model.document.deviceAliases, showsDeviceSource: model.document.proxy.allowLAN,
                     displayOptions: displayOptions)
        empty.isHidden = !records.isEmpty
        empty.update(title: history.records.isEmpty ? (history.isViewingFile ? "日志文件为空" : "等待请求") : "没有符合条件的记录", description: history.records.isEmpty ? (history.isViewingFile ? "该文件没有保存请求。" : "启动捕获，将浏览器或手机连接到代理后，请求会显示在这里。") : "调整搜索或筛选条件。", symbol: "clock")
    }
}
