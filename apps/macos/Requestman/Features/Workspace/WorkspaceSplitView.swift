import AppKit
import RequestmanCore
import SwiftUI

struct WorkspaceSplitView: NSViewControllerRepresentable {
    let model: WorkspaceModel
    let snapshot: WorkspaceToolbarSnapshot
    let openSettings: () -> Void

    func makeNSViewController(context: Context) -> WorkspaceSplitController {
        WorkspaceSplitController(model: model, snapshot: snapshot, openSettings: openSettings)
    }

    func updateNSViewController(_ controller: WorkspaceSplitController, context: Context) {
        controller.update(snapshot: snapshot, openSettings: openSettings)
    }

    static func dismantleNSViewController(_ controller: WorkspaceSplitController, coordinator: ()) {
        controller.tearDown()
    }
}

@MainActor
struct WorkspaceToolbarSnapshot {
    let section: WorkspaceSection
    let selectedRequestID: UUID?
    let hasSelectedRequest: Bool
    let environmentName: String
    let search: String
    let loaded: Bool
    let isCapturing: Bool
    let captureTitle: String
    let captureHelp: String
    let canToggleCapture: Bool

    init(model: WorkspaceModel) {
        section = model.selection
        selectedRequestID = model.history.selectedID
        hasSelectedRequest = model.history.selected != nil
        environmentName = model.document.environment?.name ?? "无环境"
        search = model.history.search
        loaded = model.loaded
        isCapturing = model.isCapturing
        captureTitle = model.captureButtonTitle
        captureHelp = model.captureButtonHelp
        canToggleCapture = model.loaded && !model.isTransitioning
            && (model.isCapturing || model.captureMode != .browser || !model.isDiscoveringBrowsers)
    }
}

@MainActor
final class WorkspaceSplitController: NSSplitViewController, NSToolbarDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    private enum Item {
        static let section = NSToolbarItem.Identifier("workspace.section")
        static let environment = NSToolbarItem.Identifier("workspace.environment")
        static let search = NSToolbarItem.Identifier("workspace.search")
        static let capture = NSToolbarItem.Identifier("workspace.capture")
        static let inspectorTitle = NSToolbarItem.Identifier("workspace.inspectorTitle")
        static let inspectorMore = NSToolbarItem.Identifier("workspace.inspectorMore")
        static let toggleSidebar = NSToolbarItem.Identifier("workspace.toggleSidebar")
        static let toggleInspector = NSToolbarItem.Identifier("workspace.toggleInspector")
    }

    private let model: WorkspaceModel
    private var state: WorkspaceToolbarSnapshot
    private var openSettings: () -> Void
    private let sidebarHost: NSHostingController<WorkspaceSidebarContent>
    private let mainHost: NSHostingController<WorkspaceMainContent>
    private let inspectorHost: NSHostingController<RequestInspectorView>
    private var sidebarItem: NSSplitViewItem!
    private var inspectorItem: NSSplitViewItem!
    private var sidebarObservation: NSKeyValueObservation?
    private var inspectorObservation: NSKeyValueObservation?
    private var rulesSidebarCollapsed = false
    private var needsInitialSidebarWidth = true
    private var needsInitialInspectorWidth = true
    private var splitTransitions: [ObjectIdentifier: UUID] = [:]
    private var inspectorContentIsPresented = false
    private var isTearingDown = false

    private let toolbar = NSToolbar(identifier: "Requestman.Workspace")
    private weak var installedWindow: NSWindow?
    private var previousToolbar: NSToolbar?
    private var previousTitleVisibility: NSWindow.TitleVisibility = .visible
    private var previousToolbarStyle: NSWindow.ToolbarStyle = .automatic
    private var insertedFullSizeContentView = false
    private let sectionControl = NSSegmentedControl(
        labels: WorkspaceSection.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil
    )
    private let environmentButton = NSButton(title: "", target: nil, action: nil)
    private let captureButton = NSButton(title: "", target: nil, action: nil)
    private let searchField = NSSearchField()
    private var environmentPopover: NSPopover?

    init(model: WorkspaceModel, snapshot: WorkspaceToolbarSnapshot, openSettings: @escaping () -> Void) {
        self.model = model
        self.state = snapshot
        self.openSettings = openSettings
        sidebarHost = NSHostingController(rootView: WorkspaceSidebarContent(model: model))
        mainHost = NSHostingController(rootView: WorkspaceMainContent(model: model))
        inspectorHost = NSHostingController(rootView: RequestInspectorView(history: model.history, isPresented: false))
        super.init(nibName: nil, bundle: nil)
        configureSplitItems()
        updateInspectorContentVisibility()
        configureToolbar()
        updateControls()
    }

    required init?(coder: NSCoder) { nil }

    private func configureSplitItems() {
        sidebarHost.sceneBridgingOptions = []
        mainHost.sceneBridgingOptions = []
        inspectorHost.sceneBridgingOptions = []
        sidebarHost.sizingOptions = []
        mainHost.sizingOptions = []
        inspectorHost.sizingOptions = []

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.minimumThickness = 260
        sidebarItem.maximumThickness = 400
        sidebarItem.allowsFullHeightLayout = true
        sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        sidebarItem.isCollapsed = state.section != .rules

        let contentItem = NSSplitViewItem(viewController: mainHost)
        contentItem.minimumThickness = 420
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorHost)
        inspectorItem.minimumThickness = 400
        inspectorItem.maximumThickness = 760
        inspectorItem.allowsFullHeightLayout = true
        inspectorItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        inspectorItem.isCollapsed = state.section != .requests || !state.hasSelectedRequest
        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        addSplitViewItem(inspectorItem)

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
        guard !isTearingDown else { return }
        let sectionChanged = state.section != next.section
        let requestChanged = state.selectedRequestID != next.selectedRequestID
        if sectionChanged, state.section == .rules { rulesSidebarCollapsed = sidebarItem.isCollapsed }
        state = next
        self.openSettings = openSettings
        if sectionChanged {
            environmentPopover?.close()
            if next.section != .requests { searchField.window?.endEditing(for: searchField) }
            setCollapsed(next.section != .rules || rulesSidebarCollapsed, item: sidebarItem)
        }
        if next.section != .requests || !next.hasSelectedRequest {
            setCollapsed(true, item: inspectorItem)
        } else if requestChanged {
            setCollapsed(false, item: inspectorItem)
        }
        updateInspectorContentVisibility()
        updateControls()
        reconcileToolbarItems()
        installToolbarIfNeeded()
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
        if state.section == .rules { rulesSidebarCollapsed = sidebarItem.isCollapsed }
        updateInspectorContentVisibility()
        reconcileToolbarItems()
        updateToggleItems()
    }

    private func updateInspectorContentVisibility() {
        let isPresented = state.section == .requests && state.hasSelectedRequest && !inspectorItem.isCollapsed
        guard inspectorContentIsPresented != isPresented else { return }
        inspectorContentIsPresented = isPresented
        inspectorHost.rootView = RequestInspectorView(history: model.history, isPresented: isPresented)
    }

    override func toggleInspector(_ sender: Any?) {
        guard state.section == .requests, state.hasSelectedRequest else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            splitTransitions.removeValue(forKey: ObjectIdentifier(inspectorItem))
            inspectorItem.isCollapsed.toggle()
        } else {
            animateTransition(of: inspectorItem) { super.toggleInspector(sender) }
        }
        splitItemStateDidChange()
    }

    override func toggleSidebar(_ sender: Any?) {
        guard state.section == .rules else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            splitTransitions.removeValue(forKey: ObjectIdentifier(sidebarItem))
            sidebarItem.isCollapsed.toggle()
        } else {
            animateTransition(of: sidebarItem) { super.toggleSidebar(sender) }
        }
        splitItemStateDidChange()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(toggleInspector(_:)) {
            return state.section == .requests && state.hasSelectedRequest
        }
        if item.action == #selector(toggleSidebar(_:)) { return state.section == .rules }
        return super.validateUserInterfaceItem(item)
    }

    private func configureToolbar() {
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.centeredItemIdentifiers = [Item.environment]
        sectionControl.target = self
        sectionControl.action = #selector(selectSection(_:))
        sectionControl.segmentStyle = .automatic
        sectionControl.segmentDistribution = .fit
        sectionControl.controlSize = .large
        if #available(macOS 26.0, *) { sectionControl.borderShape = .capsule }
        if #available(macOS 27.0, *) { sectionControl.role = .tabs }
        sectionControl.setAccessibilityLabel("工作区")
        environmentButton.target = self
        environmentButton.action = #selector(toggleEnvironment(_:))
        environmentButton.bezelStyle = .automatic
        environmentButton.setAccessibilityLabel("切换环境")
        environmentButton.toolTip = "切换环境"
        environmentButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        environmentButton.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        environmentButton.cell?.lineBreakMode = .byTruncatingTail
        captureButton.target = self
        captureButton.action = #selector(toggleCapture(_:))
        captureButton.bezelStyle = .automatic
        captureButton.imagePosition = .imageOnly
        searchField.placeholderString = "搜索 URL 或请求修改"
        searchField.setAccessibilityLabel("搜索 URL 或请求修改")
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
    }

    private func updateControls() {
        sectionControl.selectedSegment = WorkspaceSection.allCases.firstIndex(of: state.section) ?? 0
        environmentButton.title = state.environmentName
        environmentButton.setAccessibilityValue(state.environmentName)
        environmentButton.isEnabled = state.loaded
        if searchField.stringValue != state.search { searchField.stringValue = state.search }
        searchField.isEnabled = state.loaded
        // A nonempty NSButton.title changes .imageOnly to .imageOverlaps; use accessibility for the label.
        captureButton.toolTip = state.captureHelp
        captureButton.setAccessibilityLabel(state.captureTitle)
        captureButton.isEnabled = state.canToggleCapture
        captureButton.image = NSImage(systemSymbolName: state.isCapturing ? "stop.fill" : "play.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [state.isCapturing ? .systemRed : .systemGreen]))
        updateToggleItems()
    }

    private var toolbarIdentifiers: [NSToolbarItem.Identifier] {
        var identifiers: [NSToolbarItem.Identifier] = []
        if state.section == .rules { identifiers += [Item.toggleSidebar, .sidebarTrackingSeparator] }
        identifiers += [Item.section, .flexibleSpace, Item.environment, .flexibleSpace]
        if state.section == .requests { identifiers.append(Item.search) }
        identifiers.append(Item.capture)
        if state.section == .requests {
            identifiers.append(.inspectorTrackingSeparator)
            if !inspectorItem.isCollapsed { identifiers.append(Item.inspectorTitle) }
            identifiers.append(.flexibleSpace)
            if !inspectorItem.isCollapsed { identifiers.append(Item.inspectorMore) }
            identifiers.append(Item.toggleInspector)
        }
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

    private func updateToggleItems() {
        for item in toolbar.items {
            if item.itemIdentifier == Item.toggleInspector {
                item.isEnabled = state.section == .requests && state.hasSelectedRequest
                item.toolTip = inspectorItem.isCollapsed ? "展开请求详情" : "收起请求详情"
            } else if item.itemIdentifier == Item.toggleSidebar {
                item.isEnabled = state.section == .rules
                item.toolTip = sidebarItem.isCollapsed ? "展开项目侧栏" : "收起项目侧栏"
            }
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarIdentifiers }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.toggleSidebar, .sidebarTrackingSeparator, Item.section, Item.environment, Item.search,
         Item.capture, .inspectorTrackingSeparator, Item.inspectorTitle, Item.inspectorMore, .flexibleSpace, Item.toggleInspector]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == .sidebarTrackingSeparator || identifier == .inspectorTrackingSeparator {
            return NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: splitView,
                                                  dividerIndex: identifier == .sidebarTrackingSeparator ? 0 : 1)
        }
        if identifier == Item.search {
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.searchField = searchField
            item.preferredWidthForSearchField = 240
            item.label = "搜索请求"
            return item
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
            // keeps the action connected even when SwiftUI's outer window has no field focus.
            let isInspector = identifier == Item.toggleInspector
            item.image = NSImage(systemSymbolName: isInspector ? "sidebar.right" : "sidebar.left",
                                 accessibilityDescription: isInspector ? "请求详情" : "项目侧栏")
            item.label = isInspector ? "请求详情" : "项目侧栏"
            item.target = self
            item.action = isInspector ? #selector(toggleInspector(_:)) : #selector(toggleSidebar(_:))
            item.isBordered = true
            item.visibilityPriority = .high
            item.isEnabled = isInspector ? state.section == .requests && state.hasSelectedRequest : state.section == .rules
            item.toolTip = isInspector
                ? (inspectorItem.isCollapsed ? "展开请求详情" : "收起请求详情")
                : (sidebarItem.isCollapsed ? "展开项目侧栏" : "收起项目侧栏")
        case Item.section:
            item.view = sectionControl
            item.label = "工作区"
        case Item.environment:
            item.view = environmentButton
            item.label = "切换环境"
        case Item.capture:
            item.view = captureButton
            item.label = "捕获"
        case Item.inspectorTitle:
            let label = NSTextField(labelWithString: "请求详情")
            label.font = .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .title2).pointSize, weight: .semibold)
            label.textColor = .labelColor
            label.alignment = .left
            item.view = label
            item.label = "请求详情"
            item.isBordered = false
        default:
            return nil // AppKit creates its standard spacer items.
        }
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard state.section == .requests, !inspectorItem.isCollapsed,
              let record = model.history.selected else { return }
        let options: [(String, String?)] = [
            ("复制完整 URL", record.urlWasTruncated ? "URL 记录已截断，无法复制完整地址" : nil),
            ("复制原始请求为 cURL", RequestCURL.unavailableReason(for: record, version: .original)),
            ("复制修改后请求为 cURL", RequestCURL.unavailableReason(for: record, version: .modified))
        ]
        for (index, option) in options.enumerated() {
            let item = NSMenuItem(title: option.0, action: #selector(copyRequest(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            // Copy the request that the menu was opened for, even if new records arrive.
            item.representedObject = record
            item.isEnabled = option.1 == nil
            item.toolTip = option.1 ?? option.0
            menu.addItem(item)
        }
    }

    @objc private func copyRequest(_ sender: NSMenuItem) {
        guard sender.isEnabled, let record = sender.representedObject as? CaptureRecord else { return }
        let value: String?
        switch sender.tag {
        case 0: value = record.urlWasTruncated ? nil : record.url
        case 1: value = RequestCURL.command(for: record, version: .original)
        case 2: value = RequestCURL.command(for: record, version: .modified)
        default: return
        }
        if let value { RequestClipboard.copy(value) }
    }

    @objc private func selectSection(_ sender: NSSegmentedControl) {
        guard WorkspaceSection.allCases.indices.contains(sender.selectedSegment) else { return }
        model.selection = WorkspaceSection.allCases[sender.selectedSegment]
    }

    @objc private func toggleCapture(_ sender: NSButton) {
        guard state.canToggleCapture else { return }
        Task { await model.toggleCapture() }
    }

    @objc private func toggleEnvironment(_ sender: NSButton) {
        guard state.loaded else { return }
        if let environmentPopover, environmentPopover.isShown {
            environmentPopover.performClose(sender)
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        let content = EnvironmentSelectionPopover(model: model, onDismiss: { [weak popover] in
            popover?.performClose(nil)
        }, openSettings: { [weak self] in self?.openSettings() })
        let host = NSHostingController(rootView: content)
        host.sceneBridgingOptions = []
        popover.contentViewController = host
        environmentPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === searchField else { return }
        model.history.search = searchField.stringValue
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
        inspectorHost.rootView = RequestInspectorView(history: model.history, isPresented: false)
        restoreWindow()
        toolbar.delegate = nil
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
