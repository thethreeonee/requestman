import AppKit
import RequestmanCore
import Observation

@MainActor
struct WorkspaceToolbarSnapshot: Equatable {
    let section: WorkspaceSection
    let selectedRequestID: UUID?
    let selectedStepID: UUID?
    let stepKind: ModificationKind?
    let stepEnabled: Bool
    let hasSelectedStep: Bool
    let hasSelectedRequest: Bool
    let environmentName: String
    let loaded: Bool
    let isCapturing: Bool
    let requestSearch: String
    let captureTitle: String
    let captureHelp: String
    let canConnectMobile: Bool
    let canToggleCapture: Bool

    init(model: WorkspaceModel, section: WorkspaceSection? = nil) {
        self.section = section ?? model.selection
        selectedStepID = model.selectedStepID
        hasSelectedStep = model.selectedStep != nil
        stepKind = self.section == .rules ? model.selectedStep?.kind : nil
        stepEnabled = model.selectedStep?.enabled == true
        selectedRequestID = model.history.selectedID
        hasSelectedRequest = model.history.selected != nil
        environmentName = model.document.environment?.name ?? "无环境"
        canConnectMobile = model.loaded && model.isCapturing && model.listenPort != nil
            && model.activeProxyConfiguration?.allowLAN == true && !model.isTransitioning
        loaded = model.loaded
        isCapturing = model.isCapturing
        requestSearch = model.history.filter.search
        captureTitle = model.captureButtonTitle
        captureHelp = model.captureButtonHelp
        canToggleCapture = model.loaded && !model.isTransitioning
            && (model.isCapturing || model.captureMode != .browser || !model.isDiscoveringBrowsers)
    }
}

@MainActor
final class WorkspaceSplitController: NSSplitViewController, NSToolbarDelegate, NSToolbarItemValidation, NSMenuDelegate, NSSearchFieldDelegate, NSMenuItemValidation, NSPopoverDelegate, StepInspectorPresenting {
    private enum Item {
        static let logs = NSToolbarItem.Identifier("workspace.logs")
        static let environment = NSToolbarItem.Identifier("workspace.environment")
        static let search = NSToolbarItem.Identifier("workspace.requestSearch")
        static let mobile = NSToolbarItem.Identifier("workspace.mobileConnection")
        static let capture = NSToolbarItem.Identifier("workspace.capture")
        static let inspectorSeparator = NSToolbarItem.Identifier("workspace.inspectorSeparator")
        static let inspectorTitle = NSToolbarItem.Identifier("workspace.inspectorTitle")
        static let stepEnabled = NSToolbarItem.Identifier("workspace.stepEnabled")
        static let inspectorMore = NSToolbarItem.Identifier("workspace.inspectorMore")
        static let toggleSidebar = NSToolbarItem.Identifier("workspace.toggleSidebar")
        static let toggleInspector = NSToolbarItem.Identifier("workspace.toggleInspector")
    }

    private let model: WorkspaceModel
    let section: WorkspaceSection
    private var state: WorkspaceToolbarSnapshot
    private var openSettings: () -> Void
    private let sidebarHost: WorkspaceSidebarController
    private let mainHost: WorkspaceMainController
    private let inspectorHost: WorkspaceInspectorController
    private let inspectionMode: RequestInspectionMode
    private var sidebarItem: NSSplitViewItem!
    private var inspectorItem: NSSplitViewItem!
    private var sidebarObservation: NSKeyValueObservation?
    private var inspectorObservation: NSKeyValueObservation?
    private var needsInitialSidebarWidth = true
    private var needsInitialInspectorWidth = true
    private var splitTransitions: [ObjectIdentifier: UUID] = [:]
    private var inspectorContentIsPresented = false
    private var inspectorContentSection: WorkspaceSection?
    private var hasInspectorSelection: Bool { state.section == .rules ? state.hasSelectedStep : state.hasSelectedRequest }
    private var canToggleInspector: Bool {
        !inspectorItem.isCollapsed || (section == .rules ? model.selectedStep != nil : model.history.selected != nil)
    }
    private var inspectorTitle: String { state.section == .rules ? "步骤详情" : "请求详情" }
    private var isTearingDown = false

    private let toolbar: NSToolbar
    private let inspectorTitleLabel = NativeUI.label("", size: NSFont.preferredFont(forTextStyle: .title2).pointSize, weight: .semibold)
    private let inspectorAnnotationLabel = NativeUI.label("", size: 11, secondary: true)
    private let inspectorTypeIcon = NSImageView()
    private let stepEnabledSwitch = NSSwitch()
    private let stepEnabledLabel = NativeUI.label("", size: 11, secondary: true)
    // A layout-only host prevents NSToolbar from promoting the switch to its toolbar control size.
    private lazy var stepEnabledHost = NativeUI.stack([stepEnabledLabel, stepEnabledSwitch], vertical: false, spacing: 6)
    private lazy var inspectorTitleRow = NativeUI.stack([inspectorTypeIcon, inspectorTitleLabel], vertical: false, spacing: 6)
    private lazy var inspectorHeading = NativeUI.stack([inspectorTitleRow, inspectorAnnotationLabel], spacing: 4)
    private weak var installedWindow: NSWindow?
    private var previousToolbar: NSToolbar?
    private var previousTitleVisibility: NSWindow.TitleVisibility = .visible
    private var previousToolbarStyle: NSWindow.ToolbarStyle = .automatic
    private var insertedFullSizeContentView = false
    private let environmentButton = NSButton(title: "", target: nil, action: nil)
    private let requestSearchItem = NSSearchToolbarItem(itemIdentifier: Item.search)
    private let captureButton = NSButton(title: "", target: nil, action: nil)
    private var environmentPopover: NSPopover?
    private weak var environmentPreviousFocus: NSResponder?

    init(model: WorkspaceModel, snapshot: WorkspaceToolbarSnapshot, openSettings: @escaping () -> Void) {
        self.model = model
        self.section = snapshot.section
        self.state = snapshot
        self.openSettings = openSettings
        // AppKit synchronizes toolbars with the same identifier even without autosaving.
        toolbar = NSToolbar(identifier: snapshot.section == .rules ? "Requestman.RulesToolbar" : "Requestman.RequestLogsToolbar")
        sidebarHost = WorkspaceSidebarController(model: model)
        mainHost = WorkspaceMainController(model: model, section: snapshot.section)
        let inspectionMode = RequestInspectionMode()
        self.inspectionMode = inspectionMode
        inspectorHost = WorkspaceInspectorController(model: model, mode: inspectionMode)
        super.init(nibName: nil, bundle: nil)
        configureSplitItems()
        updateInspectorContentVisibility()
        configureToolbar()
        updateControls()
        observeModel()
    }

    required init?(coder: NSCoder) { nil }

    private func observeModel() {
        guard !isTearingDown else { return }
        let snapshot = withObservationTracking {
            WorkspaceToolbarSnapshot(model: model, section: section)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeModel() }
        }
        update(snapshot: snapshot, openSettings: openSettings)
    }

    private func configureSplitItems() {
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.minimumThickness = 260
        sidebarItem.maximumThickness = 400
        sidebarItem.allowsFullHeightLayout = true
        sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        sidebarItem.isCollapsed = state.section != .rules

        let contentItem = NSSplitViewItem(viewController: mainHost)
        contentItem.minimumThickness = state.section == .requests ? mainHost.requests.minimumContentWidth : 420
        if #available(macOS 26.0, *) { contentItem.allowsFullHeightLayout = true }
        inspectorItem = NSSplitViewItem(sidebarWithViewController: inspectorHost)
        inspectorItem.minimumThickness = 400
        inspectorItem.maximumThickness = 760
        inspectorItem.allowsFullHeightLayout = true
        inspectorItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        inspectorItem.isCollapsed = !hasInspectorSelection
        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        addSplitViewItem(inspectorItem)
        if section == .rules {
            sidebarHost.sidebar.installBottomAccessory(on: sidebarItem)
            mainHost.rules.installBottomAccessory(on: contentItem)
            inspectorHost.steps.installAccessories(on: inspectorItem)
        } else {
            mainHost.requests.installFilterAccessory(on: contentItem, visible: true)
        }


        sidebarObservation = sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.splitItemStateDidChange() }
        }
        inspectorObservation = inspectorItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.splitItemStateDidChange() }
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        installToolbarIfNeeded()
        view.needsLayout = true
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard view.window != nil else { return }
        let dividerWidth = CGFloat(splitViewItems.filter { !$0.isCollapsed }.count - 1) * splitView.dividerThickness
        let contentMinimum = splitViewItems[1].minimumThickness
        // Set each divider once, when its pane first has room. Subsequent sizes belong to AppKit and the user.
        if needsInitialSidebarWidth, !sidebarItem.isCollapsed, splitTransitions[ObjectIdentifier(sidebarItem)] == nil {
            let inspectorWidth = inspectorItem.isCollapsed ? 0 : max(inspectorHost.view.bounds.width, inspectorItem.minimumThickness)
            if splitView.bounds.width >= 320 + contentMinimum + inspectorWidth + dividerWidth {
                needsInitialSidebarWidth = false
                splitView.setPosition(splitView.bounds.minX + 320, ofDividerAt: 0)
            }
        }
        if needsInitialInspectorWidth, !inspectorItem.isCollapsed, splitTransitions[ObjectIdentifier(inspectorItem)] == nil {
            let sidebarWidth = sidebarItem.isCollapsed ? 0 : max(sidebarHost.view.bounds.width, sidebarItem.minimumThickness)
            if splitView.bounds.width >= 520 + contentMinimum + sidebarWidth + dividerWidth {
                needsInitialInspectorWidth = false
                splitView.setPosition(splitView.bounds.maxX - 520 - splitView.dividerThickness, ofDividerAt: 1)
            }
        }
    }

    func update(snapshot next: WorkspaceToolbarSnapshot, openSettings: @escaping () -> Void) {
        guard !isTearingDown, next.section == section else { return }
        self.openSettings = openSettings
        // Parent layout/observation can deliver the same snapshot repeatedly.
        // Avoid reassigning native control images, titles and selection each time.
        guard state != next else { installToolbarIfNeeded(); return }
        let requestChanged = state.selectedRequestID != next.selectedRequestID
        let stepChanged = state.selectedStepID != next.selectedStepID
        state = next
        if !hasInspectorSelection {
            setCollapsed(true, item: inspectorItem)
        } else if next.section == .requests ? requestChanged : stepChanged {
            setCollapsed(false, item: inspectorItem)
        }
        updateInspectorContentVisibility()
        updateControls()
        reconcileToolbarItems()
        installToolbarIfNeeded()
    }

    func showStepInspector(_ sender: Any?) {
        guard !isTearingDown, state.section == .rules, model.selectedStep != nil else { return }
        // Selection observation may still be queued when the table sends its action.
        update(snapshot: WorkspaceToolbarSnapshot(model: model, section: section), openSettings: openSettings)
        setCollapsed(false, item: inspectorItem)
        updateInspectorContentVisibility()
        reconcileToolbarItems()
        updateToggleItems()
    }

    func toggleStepInspector(_ sender: Any?) {
        guard !isTearingDown, state.section == .rules, model.selectedStep != nil else { return }
        let shouldCollapse = !inspectorItem.isCollapsed
        // Consume pending selection changes before applying the user's explicit toggle.
        update(snapshot: WorkspaceToolbarSnapshot(model: model, section: section), openSettings: openSettings)
        if shouldCollapse { releaseFocus(in: inspectorHost.view) }
        setCollapsed(shouldCollapse, item: inspectorItem)
        splitItemStateDidChange()
    }

    private func setCollapsed(_ collapsed: Bool, item: NSSplitViewItem) {
        guard item.isCollapsed != collapsed else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || view.window == nil {
            splitTransitions.removeValue(forKey: ObjectIdentifier(item))
            item.isCollapsed = collapsed
        } else {
            animateTransition(of: item) { item.animator().isCollapsed = collapsed }
        }
    }

    private func animateTransition(of item: NSSplitViewItem, changes: () -> Void) {
        let key = ObjectIdentifier(item)
        let transition = UUID()
        splitTransitions[key] = transition
        NSAnimationContext.runAnimationGroup({ _ in
            changes()
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isTearingDown, self.splitTransitions[key] == transition else { return }
                self.splitTransitions.removeValue(forKey: key)
                // Native collapse animation owns its final frames until completion.
                self.view.needsLayout = true
                self.view.layoutSubtreeIfNeeded()
            }
        })
    }

    private func splitItemStateDidChange() {
        guard !isTearingDown else { return }
        updateInspectorContentVisibility()
        reconcileToolbarItems()
        updateToggleItems()
    }

    private func updateInspectorContentVisibility() {
        let isPresented = hasInspectorSelection && !inspectorItem.isCollapsed
        guard inspectorContentIsPresented != isPresented || inspectorContentSection != state.section else { return }
        inspectorContentIsPresented = isPresented
        inspectorContentSection = state.section
        inspectorHost.update(section: state.section, isPresented: isPresented)
    }

    override func toggleInspector(_ sender: Any?) {
        guard canToggleInspector else { return }
        if !inspectorItem.isCollapsed { releaseFocus(in: inspectorHost.view) }
        setCollapsed(!inspectorItem.isCollapsed, item: inspectorItem)
        splitItemStateDidChange()
    }

    @objc private func toggleDetailsPane(_ sender: Any?) {
        toggleInspector(sender)
    }

    override func toggleSidebar(_ sender: Any?) {
        guard state.section == .rules else { return }
        if !sidebarItem.isCollapsed { releaseFocus(in: sidebarHost.view) }
        setCollapsed(!sidebarItem.isCollapsed, item: sidebarItem)
        splitItemStateDidChange()
    }

    private func releaseFocus(in pane: NSView) {
        let responder = view.window?.firstResponder
        let focusedView: NSView?
        if let editor = responder as? NSTextView, editor.isFieldEditor {
            focusedView = editor.delegate as? NSView
        } else { focusedView = responder as? NSView }
        if let focusedView, focusedView.isDescendant(of: pane) { view.window?.makeFirstResponder(nil) }
        view.window?.recalculateKeyViewLoop()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == WorkspaceCommand.action, let command = WorkspaceCommand(rawValue: item.tag) {
            return canPerform(command)
        }
        if item.action == #selector(toggleInspector(_:)) || item.action == #selector(toggleDetailsPane(_:)) {
            return canToggleInspector
        }
        if item.action == #selector(toggleSidebar(_:)) { return state.section == .rules }
        return super.validateUserInterfaceItem(item)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard !isTearingDown else { return false }
        switch item.itemIdentifier {
        case Item.toggleInspector: return canToggleInspector
        case Item.toggleSidebar, Item.logs: return section == .rules
        case Item.mobile: return state.canConnectMobile
        case Item.inspectorMore: return section == .requests && !inspectorItem.isCollapsed && hasInspectorSelection
        default: return true
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == WorkspaceCommand.action, let command = WorkspaceCommand(rawValue: item.tag) else {
            return validateUserInterfaceItem(item)
        }
        switch command {
        case .capture: item.title = model.captureButtonTitle
        case .recording: item.title = model.history.paused ? "恢复记录" : "暂停记录"
        case .rules: item.state = state.section == .rules ? .on : .off
        case .requests: item.state = state.section == .requests ? .on : .off
        default: break
        }
        return canPerform(command)
    }

    func canPerform(_ command: WorkspaceCommand) -> Bool {
        guard !isTearingDown, model.loaded, let window = view.window,
              window.isKeyWindow, window.attachedSheet == nil else { return false }
        switch command {
        case .capture: return WorkspaceToolbarSnapshot(model: model, section: section).canToggleCapture
        case .importRules, .exportRules: return !model.isTransitioning
        case .saveLog: return state.section == .requests && !model.history.recordsForSaving.isEmpty
        case .openLog: return true
        case .recording: return state.section == .requests && !model.history.isViewingFile
        case .filters: return state.section == .requests
        case .clear: return state.section == .requests && !model.history.isViewingFile && !model.history.records.isEmpty
        case .sidebar, .environment: return state.section == .rules
        case .inspector: return canToggleInspector
        case .copyURL:
            return state.section == .requests && model.history.selected.map { !$0.urlWasTruncated } == true
        case .copyCURL:
            return state.section == .requests && model.history.selected.map { RequestCURL.unavailableReason(for: $0, version: .original) == nil } == true
        case .duplicate, .rename, .delete, .toggleEnabled:
            return state.section == .rules && (sidebarHost.sidebar.canPerform(command) || mainHost.rules.canPerform(command))
        default: return true
        }
    }

    @objc func performWorkspaceCommand(_ sender: NSMenuItem) {
        guard let command = WorkspaceCommand(rawValue: sender.tag), canPerform(command) else { return }
        switch command {
        case .rules, .requests:
            model.selection = command == .rules ? .rules : .requests
        case .capture: toggleCapture(captureButton)
        case .importRules: WorkspaceTransfer.importFile(model: model, window: view.window, rulesOnly: true)
        case .exportRules: WorkspaceTransfer.exportRules(model: model, window: view.window)
        case .saveLog: RequestLogTransfer.save(records: model.history.recordsForSaving, window: view.window)
        case .openLog: RequestLogTransfer.open(model: model, window: view.window)
        case .recording: model.setRecordingPaused(!model.history.paused)
        case .clear: model.clearHistory()
        case .filters: mainHost.requests.showFilters()
        case .sidebar: toggleSidebar(sender)
        case .inspector: toggleInspector(sender)
        case .environment: toggleEnvironment(environmentButton)
        case .search:
            if state.section == .rules {
                // Focus only after making the collapsed pane available to AppKit.
                sidebarItem.isCollapsed = false
                splitItemStateDidChange()
                sidebarHost.sidebar.searchField.selectText(nil)
            } else {
                requestSearchItem.beginSearchInteraction()
                requestSearchItem.searchField.selectText(nil)
            }
        case .newWorkflow, .newProject:
            model.selection = .rules
            update(snapshot: WorkspaceToolbarSnapshot(model: model, section: section), openSettings: openSettings)
            sidebarItem.isCollapsed = false
            splitItemStateDidChange()
            if command == .newProject { sidebarHost.sidebar.createProject() }
            else { sidebarHost.sidebar.addRequest(); mainHost.rules.focusName() }
            view.window?.recalculateKeyViewLoop()
        case .duplicate, .rename, .delete, .toggleEnabled:
            if sidebarHost.sidebar.canPerform(command) { sidebarHost.sidebar.perform(command) }
            else { mainHost.rules.perform(command) }
        case .copyURL:
            if let record = model.history.selected { RequestClipboard.copy(record.url) }
        case .copyCURL:
            if let record = model.history.selected, let text = RequestCURL.command(for: record, version: .original) {
                RequestClipboard.copy(text)
            }
        }
    }

    private func configureToolbar() {
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.centeredItemIdentifiers = []
        environmentButton.target = self
        environmentButton.action = #selector(toggleEnvironment(_:))
        environmentButton.bezelStyle = .automatic
        environmentButton.setAccessibilityLabel("切换环境")
        environmentButton.toolTip = "切换环境（⌘⇧E）"
        environmentButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        environmentButton.widthAnchor.constraint(lessThanOrEqualToConstant: 140).isActive = true
        environmentButton.cell?.lineBreakMode = .byTruncatingTail
        let search = NSSearchField()
        search.placeholderString = "搜索当前显示列"
        search.toolTip = "搜索当前显示列的内容（⌘F）"
        search.setAccessibilityLabel("搜索当前显示列")
        search.sendsSearchStringImmediately = true
        search.delegate = self
        search.target = self
        search.action = #selector(searchRequests(_:))
        requestSearchItem.searchField = search
        requestSearchItem.label = "筛选请求日志"
        requestSearchItem.preferredWidthForSearchField = 260
        requestSearchItem.visibilityPriority = .high
        captureButton.target = self
        captureButton.action = #selector(toggleCapture(_:))
        captureButton.bezelStyle = .automatic
        captureButton.imagePosition = .imageOnly
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField,
              field === requestSearchItem.searchField else { return }
        searchRequests(field)
    }

    @objc private func searchRequests(_ sender: NSSearchField) {
        guard !isTearingDown, state.section == .requests else { return }
        model.history.filter.search = sender.stringValue
    }

    private func updateControls() {
        if requestSearchItem.searchField.stringValue != state.requestSearch {
            requestSearchItem.searchField.stringValue = state.requestSearch
        }
        environmentButton.title = state.environmentName
        environmentButton.setAccessibilityValue(state.environmentName)
        environmentButton.isEnabled = state.loaded
        // A nonempty NSButton.title changes .imageOnly to .imageOverlaps; use accessibility for the label.
        captureButton.toolTip = state.captureHelp + "（⌘R）"
        captureButton.setAccessibilityLabel(state.captureTitle)
        captureButton.isEnabled = state.canToggleCapture
        captureButton.image = NSImage(systemSymbolName: state.isCapturing ? "stop.fill" : "play.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [state.isCapturing ? .systemRed : .systemGreen]))
        updateToggleItems()
    }

    private var toolbarIdentifiers: [NSToolbarItem.Identifier] {
        var identifiers: [NSToolbarItem.Identifier] = []
        if state.section == .rules {
            identifiers += [Item.toggleSidebar, Item.environment, .sidebarTrackingSeparator]
        }
        identifiers += [Item.capture, .flexibleSpace]
        if state.section == .requests { identifiers.append(Item.search) }
        if state.section == .rules {
            identifiers.append(Item.logs)
            // Keep the log action separate when the inspector's tracking separator is absent.
            if inspectorItem.isCollapsed { identifiers.append(.space) }
        }
        // Keep the mobile action in the main pane when the inspector has its own toolbar region.
        if state.canConnectMobile, !inspectorItem.isCollapsed { identifiers.append(Item.mobile) }
        if !inspectorItem.isCollapsed {
            identifiers += [Item.inspectorSeparator, Item.inspectorTitle, .flexibleSpace]
        }
        if state.section == .requests, !inspectorItem.isCollapsed { identifiers += [Item.inspectorMore] }
        if state.section == .rules, !inspectorItem.isCollapsed {
            // A native spacer separates the toolbar's automatic glass groups.
            identifiers += [Item.stepEnabled, .space]
        }
        if state.canConnectMobile, inspectorItem.isCollapsed { identifiers += [Item.mobile, .space] }
        identifiers.append(Item.toggleInspector)
        return identifiers
    }

    private func reconcileToolbarItems() {
        guard installedWindow != nil else { return }
        let identifiers = toolbarIdentifiers
        if #available(macOS 15.0, *) {
            if toolbar.itemIdentifiers != identifiers { toolbar.itemIdentifiers = identifiers }
        } else {
            for (index, identifier) in identifiers.enumerated() {
                if index < toolbar.items.count, toolbar.items[index].itemIdentifier == identifier { continue }
                if let oldIndex = toolbar.items.indices.dropFirst(index).first(where: { toolbar.items[$0].itemIdentifier == identifier }) {
                    toolbar.removeItem(at: oldIndex)
                }
                toolbar.insertItem(withItemIdentifier: identifier, at: index)
            }
            while toolbar.items.count > identifiers.count { toolbar.removeItem(at: toolbar.items.count - 1) }
        }
    }

    private func installToolbarIfNeeded() {
        guard !isTearingDown, let window = view.window, installedWindow !== window else { return }
        restoreWindow()
        installedWindow = window
        previousToolbar = window.toolbar
        previousTitleVisibility = window.titleVisibility
        previousToolbarStyle = window.toolbarStyle
        insertedFullSizeContentView = !window.styleMask.contains(.fullSizeContentView)
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.toolbar = toolbar
        reconcileToolbarItems()
        updateToggleItems()
    }

    private func updateInspectorHeading() {
        inspectorTitleLabel.stringValue = state.stepKind?.title ?? inspectorTitle
        inspectorTypeIcon.image = state.stepKind.flatMap { NSImage(systemSymbolName: $0.symbolName, accessibilityDescription: nil) }
        inspectorTypeIcon.isHidden = state.stepKind == nil
        inspectorTypeIcon.symbolConfiguration = .init(pointSize: inspectorTitleLabel.font!.pointSize, weight: .semibold)
        inspectorTypeIcon.contentTintColor = .labelColor
        inspectorTypeIcon.setAccessibilityElement(false)
        inspectorAnnotationLabel.stringValue = state.stepKind?.stepDescription ?? ""
        inspectorAnnotationLabel.toolTip = state.stepKind?.stepDescription
        inspectorAnnotationLabel.isHidden = state.stepKind == nil
        inspectorAnnotationLabel.identifier = .init("workspace.stepAnnotation")
    }

    private func updateToggleItems() {
        stepEnabledSwitch.state = state.stepEnabled ? .on : .off
        stepEnabledSwitch.isEnabled = state.loaded && state.hasSelectedStep
        stepEnabledSwitch.toolTip = state.stepEnabled ? "停用当前步骤" : "启用当前步骤"
        stepEnabledLabel.stringValue = state.stepEnabled ? "已启用" : "已停用"
        stepEnabledLabel.textColor = stepEnabledSwitch.isEnabled ? .secondaryLabelColor : .disabledControlTextColor
        for item in toolbar.items {
            if item.itemIdentifier == Item.toggleInspector {
                item.isEnabled = canToggleInspector
                item.label = inspectorTitle
                item.toolTip = (inspectorItem.isCollapsed ? "展开" : "收起") + inspectorTitle + "（⌘⌥I）"
            } else if item.itemIdentifier == Item.mobile {
                item.isEnabled = state.canConnectMobile
            } else if item.itemIdentifier == Item.inspectorTitle {
                updateInspectorHeading()
                item.label = inspectorTitle
            } else if item.itemIdentifier == Item.toggleSidebar {
                item.isEnabled = state.section == .rules
                item.toolTip = (sidebarItem.isCollapsed ? "展开规则组侧栏" : "收起规则组侧栏") + "（⌘⌥S）"
            }
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarIdentifiers }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.toggleSidebar, .sidebarTrackingSeparator, Item.logs, Item.environment,
         Item.search, Item.capture, Item.mobile, Item.inspectorSeparator, Item.inspectorTitle, Item.inspectorMore, Item.stepEnabled,
         .space, .flexibleSpace, Item.toggleInspector]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == Item.search { return requestSearchItem }
        if identifier == .sidebarTrackingSeparator || identifier == Item.inspectorSeparator {
            return NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: splitView,
                                                  dividerIndex: identifier == .sidebarTrackingSeparator ? 0 : 1)
        }
        if identifier == Item.inspectorMore {
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "更多请求操作")
            item.label = "更多请求操作"
            item.toolTip = "更多请求操作"
            item.isBordered = true
            item.showsIndicator = false
            item.visibilityPriority = .high
            let menu = NSMenu(title: "更多请求操作")
            menu.autoenablesItems = false
            menu.delegate = self
            menuNeedsUpdate(menu)
            item.menu = menu
            return item
        }
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier {
        case Item.toggleSidebar, Item.toggleInspector:
            // Reserved toggle identifiers discard explicit targets. A native toolbar button
            // keeps the action connected even when the window has no field focus.
            let isInspector = identifier == Item.toggleInspector
            item.image = NSImage(systemSymbolName: isInspector ? "sidebar.right" : "sidebar.left",
                                 accessibilityDescription: isInspector ? inspectorTitle : "规则组侧栏")
            item.label = isInspector ? inspectorTitle : "规则组侧栏"
            item.target = self
            // The right pane uses the sidebar role; avoid the system inspector action's role-based validation.
            item.action = isInspector ? #selector(toggleDetailsPane(_:)) : #selector(toggleSidebar(_:))
            item.isBordered = true
            item.visibilityPriority = .high
            item.isEnabled = isInspector ? canToggleInspector : state.section == .rules
            item.toolTip = isInspector
                ? ((inspectorItem.isCollapsed ? "展开" : "收起") + inspectorTitle + "（⌘⌥I）")
                : ((sidebarItem.isCollapsed ? "展开规则组侧栏" : "收起规则组侧栏") + "（⌘⌥S）")
        case Item.mobile:
            item.image = NSImage(systemSymbolName: "iphone.gen3", accessibilityDescription: "连接手机")
            item.label = "连接手机"
            item.toolTip = "连接手机"
            item.target = self
            item.action = #selector(showMobileConnection(_:))
            item.isBordered = true
            item.visibilityPriority = .high
            item.isEnabled = state.loaded
        case Item.logs:
            item.image = NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: "打开请求日志")
            item.label = "请求日志"
            item.toolTip = "打开请求日志（⌘2）"
            item.target = self
            item.action = #selector(showLogs(_:))
            item.isBordered = true
            item.visibilityPriority = .high
        case Item.environment:
            item.view = environmentButton
            item.label = "切换环境"
        case Item.capture:
            item.view = captureButton
            item.label = "捕获"
        case Item.inspectorTitle:
            updateInspectorHeading()
            item.view = inspectorHeading
            item.label = inspectorTitle
            item.isBordered = false
        case Item.stepEnabled:
            stepEnabledSwitch.controlSize = .small
            stepEnabledSwitch.target = self
            stepEnabledSwitch.action = #selector(changeStepEnabled(_:))
            stepEnabledSwitch.setAccessibilityLabel("启用当前步骤")
            stepEnabledSwitch.state = state.stepEnabled ? .on : .off
            stepEnabledSwitch.isEnabled = state.loaded && state.hasSelectedStep
            stepEnabledSwitch.toolTip = state.stepEnabled ? "停用当前步骤" : "启用当前步骤"
            item.view = stepEnabledHost
            item.label = "启用当前步骤"
            item.isBordered = false
            item.visibilityPriority = .high
        default:
            return nil // AppKit creates its standard spacer items.
        }
        return item
    }

    @objc private func changeStepEnabled(_ sender: NSSwitch) {
        guard !isTearingDown, model.loaded, state.section == .rules,
              !inspectorItem.isCollapsed, var workflow = model.workflow,
              let stepID = model.selectedStepID else { return }
        var steps = model.editingResponse ? workflow.responseSteps : workflow.requestSteps
        guard let index = steps.firstIndex(where: { $0.id == stepID }) else { return }
        steps[index].enabled = sender.state == .on
        if model.editingResponse { workflow.responseSteps = steps } else { workflow.requestSteps = steps }
        model.updateWorkflow(workflow)
        update(snapshot: WorkspaceToolbarSnapshot(model: model, section: section), openSettings: openSettings)
    }

    @objc private func showMobileConnection(_ sender: NSToolbarItem) {
        guard !isTearingDown, WorkspaceToolbarSnapshot(model: model, section: section).canConnectMobile,
              let window = view.window, window.attachedSheet == nil else { return }
        presentAsSheet(MobileConnectionViewController(model: model))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard state.section == .requests, !inspectorItem.isCollapsed,
              let record = model.history.selected else { return }
        RequestActionsMenu.append(to: menu, record: record, replayUnavailable: model.replayUnavailableReason,
                                  cancelReplay: { [weak model] in model?.cancelReplay($0) },
                                  revealSource: record.replaySourceID.flatMap { id in
                                      model.history.records.contains { $0.id == id } ? { [weak model] id in model?.history.reveal(id) } : nil
                                  },
                                  contentCopyItem: inspectorHost.requests.makeContentCopyMenuItem()) { [weak self] record, editing in
            guard let self else { return }
            model.replay(record, editing: editing, presenter: self)
        }
        menu.addItem(.separator())
        let display = NSMenuItem(title: "显示选项", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "显示选项"); submenu.autoenablesItems = false
        for version in InspectionVersion.allCases {
            let item = RequestActionsMenu.item(version.title) { [weak self] in self?.inspectionMode.version = version }
            item.state = inspectionMode.version == version ? .on : .off
            submenu.addItem(item)
        }
        display.submenu = submenu; menu.addItem(display)
    }

    @objc private func showLogs(_ sender: NSToolbarItem) {
        model.selection = .requests
    }

    @objc private func toggleCapture(_ sender: NSButton) {
        guard WorkspaceToolbarSnapshot(model: model, section: section).canToggleCapture else { return }
        Task { await model.toggleCapture() }
    }

    @objc private func toggleEnvironment(_ sender: NSButton) {
        guard state.loaded, state.section == .rules else { return }
        if let environmentPopover, environmentPopover.isShown {
            environmentPopover.performClose(sender)
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        if let editor = view.window?.firstResponder as? NSTextView, editor.isFieldEditor {
            environmentPreviousFocus = editor.delegate as? NSResponder
        } else { environmentPreviousFocus = view.window?.firstResponder }
        let content = EnvironmentSelectionPopover(model: model, onDismiss: { [weak popover] in
            popover?.performClose(nil)
        }, openSettings: { [weak self] in self?.openSettings() })
        popover.contentViewController = content
        environmentPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover, popover === environmentPopover else { return }
        if let previousView = environmentPreviousFocus as? NSView, previousView.window === view.window,
           !previousView.isHiddenOrHasHiddenAncestor {
            view.window?.makeFirstResponder(previousView)
        } else { view.window?.makeFirstResponder(environmentButton) }
        environmentPreviousFocus = nil
    }

    func tearDown() {
        isTearingDown = true
        sidebarObservation?.invalidate()
        inspectorObservation?.invalidate()
        sidebarObservation = nil
        inspectorObservation = nil
        splitTransitions.removeAll()
        environmentPopover?.close()
        environmentPopover = nil
        inspectorHost.update(section: state.section, isPresented: false)
        restoreWindow()
        toolbar.delegate = nil
        requestSearchItem.searchField.delegate = nil
        requestSearchItem.searchField.target = nil
    }

    private func restoreWindow() {
        if let window = installedWindow, window.toolbar === toolbar {
            window.toolbar = previousToolbar
            window.titleVisibility = previousTitleVisibility
            window.toolbarStyle = previousToolbarStyle
            if insertedFullSizeContentView { window.styleMask.remove(.fullSizeContentView) }
        }
        installedWindow = nil
        previousToolbar = nil
    }
}
