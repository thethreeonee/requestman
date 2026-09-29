import AppKit
import QuartzCore

/// Step actions target the owning workspace instead of AppKit's generic inspector action.
@MainActor @objc protocol StepInspectorPresenting {
    func showStepInspector(_ sender: Any?)
    func toggleStepInspector(_ sender: Any?)
}

@MainActor @objc protocol RequestInspectorPresenting {
    func toggleRequestInspector(_ sender: Any?)
}

/// Business commands have explicit targets; standard text editing retains the responder chain.
@MainActor
enum WorkspaceCommand: Int, CaseIterable {
    case newWorkflow, newProject, duplicate, rename, delete, toggleEnabled
    case rules, requests, search, filters, sidebar, inspector, environment
    case capture, recording, clear, copyURL, copyCURL
    case importRules, exportRules, saveLog, openLog

    var title: String {
        switch self {
        case .newWorkflow: "新建请求修改"
        case .newProject: "新建规则组"
        case .duplicate: "复制选中项"
        case .rename: "重命名"
        case .delete: "删除选中项"
        case .toggleEnabled: "启用 / 停用选中项"
        case .rules: "规则配置"
        case .requests: "请求日志"
        case .search: "搜索当前页面"
        case .filters: "日志筛选…"
        case .sidebar: "显示 / 隐藏规则组侧栏"
        case .inspector: "显示 / 隐藏详情"
        case .environment: "切换环境…"
        case .capture: "开始捕获"
        case .recording: "暂停记录"
        case .clear: "清空请求日志"
        case .copyURL: "复制完整 URL"
        case .copyCURL: "复制原始请求为 cURL"
        case .importRules: "导入规则…"
        case .exportRules: "导出全部规则…"
        case .saveLog: "保存当前日志…"
        case .openLog: "打开日志文件…"
        }
    }
    var key: String {
        switch self {
        case .newWorkflow, .newProject: "n"
        case .duplicate: "d"
        case .rename: "\r"
        case .delete: "\u{8}"
        case .toggleEnabled: "l"
        case .rules: "1"
        case .requests: "2"
        case .search, .filters: "f"
        case .sidebar, .saveLog: "s"
        case .inspector: "i"
        case .environment: "e"
        case .capture, .recording: "r"
        case .clear: "k"
        case .copyURL, .copyCURL: "c"
        case .importRules, .exportRules: ""
        case .openLog: "o"
        }
    }
    var modifiers: NSEvent.ModifierFlags {
        switch self {
        case .rename, .importRules, .exportRules: []
        case .newProject, .toggleEnabled, .environment, .recording, .copyURL: [.command, .shift]
        case .filters, .sidebar, .inspector, .copyCURL: [.command, .option]
        default: [.command]
        }
    }
    static let action = NSSelectorFromString("performWorkspaceCommand:")
    func menuItem(target: AnyObject? = nil) -> NSMenuItem {
        let equivalent = modifiers.contains(.shift) ? key.uppercased() : key
        let item = NSMenuItem(title: title, action: Self.action, keyEquivalent: equivalent)
        item.keyEquivalentModifierMask = modifiers
        item.tag = rawValue
        item.target = target
        return item
    }
}

import Observation

/// Re-registers one-shot model observation without polling or replacing the view hierarchy.
@MainActor
class ObservedViewController: NSViewController {
    private var observationGeneration = 0
    private var observing = true

    init() { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        NativeTextEditing.install()
        observeModel()
    }

    func refresh() {}

    final func observeModel() {
        guard observing, isViewLoaded else { return }
        observationGeneration += 1
        let generation = observationGeneration
        withObservationTracking { refresh() } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observing, self.observationGeneration == generation else { return }
                self.observeModel()
            }
        }
    }

    func stopObserving() { observing = false; observationGeneration += 1 }
}

/// Finish editing before a click elsewhere is delivered to its original target.
@MainActor
enum NativeTextEditing {
    private static var mouseMonitor: Any?

    static func install() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated { finishEditingOutside(event) }
            return event
        }
    }

    static func finishEditingOutside(_ event: NSEvent) {
        guard let window = event.window, let root = window.contentView,
              let editor = window.firstResponder as? NSTextView, editor.isEditable else { return }
        let owner: NSView
        if editor.isFieldEditor, let field = editor.delegate as? NSTextField {
            owner = field
        } else {
            owner = editor.enclosingScrollView ?? editor
        }
        let point = root.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        if let hit = root.hitTest(point),
           hit === owner || hit.isDescendant(of: owner) || hit === editor || hit.isDescendant(of: editor) {
            return
        }
        window.makeFirstResponder(nil)
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
enum NativeUI {
    static func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                      secondary: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    static func stack(_ views: [NSView], vertical: Bool = true, spacing: CGFloat = 10) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = vertical ? .vertical : .horizontal
        stack.alignment = vertical ? .leading : .centerY
        stack.spacing = spacing
        stack.detachesHiddenViews = true
        return stack
    }

    static func pin(_ child: NSView, to parent: NSView,
                    insets: NSEdgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)) {
        child.translatesAutoresizingMaskIntoConstraints = false
        if child.superview !== parent { parent.addSubview(child) }
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: insets.left),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -insets.right),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: insets.top),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -insets.bottom)
        ])
    }

    static func separator() -> NSBox {
        let box = NSBox(); box.boxType = .separator; return box
    }
}

@MainActor
final class ActionButton: NSButton {
    var handler: () -> Void
    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self; self.action = #selector(invoke(_:))
    }
    required init?(coder: NSCoder) { nil }
    @objc private func invoke(_ sender: NSButton) { guard isEnabled else { return }; handler() }
}

@MainActor
final class ActionPopUpButton: NSPopUpButton {
    var onChange: (Int) -> Void
    init(items: [String], onChange: @escaping (Int) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero, pullsDown: false)
        addItems(withTitles: items)
        target = self; action = #selector(selectItemAction(_:))
    }
    required init?(coder: NSCoder) { nil }
    @objc private func selectItemAction(_ sender: NSPopUpButton) {
        guard isEnabled, indexOfSelectedItem >= 0 else { return }
        onChange(indexOfSelectedItem)
    }
}

/// Shared row hover feedback; subclasses retain their own selection and content appearance.
@MainActor class HoverTableRowView: NSTableRowView {
    private let hoverLayer = CALayer()
    private var hoverTrackingArea: NSTrackingArea?
    private(set) var isHovered = false
    var isShowingMenu = false { didSet { updateFeedback(animated: false) } }
    var hoverLayerPrefix: String { "row" }
    var hoverBackgroundRect: NSRect { bounds.insetBy(dx: 10, dy: 1) }
    var hoverCornerRadius: CGFloat { 6 }
    private var animationKey: String { "\(hoverLayerPrefix).hoverOpacity" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        hoverLayer.name = "\(hoverLayerPrefix).hoverBackground"
        hoverLayer.opacity = 0
        hoverLayer.cornerRadius = hoverCornerRadius
        layer?.insertSublayer(hoverLayer, at: 0)
        updateHoverColor()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { nil }

    override var isSelected: Bool { didSet { if oldValue != isSelected { updateFeedback(animated: false) } } }
    override var isEmphasized: Bool { didSet { if oldValue != isEmphasized { updateFeedback(animated: false) } } }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        hoverLayer.frame = hoverBackgroundRect
        CATransaction.commit()
        refreshHover()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverTrackingArea = area
        refreshHover()
    }
    override func mouseEntered(with event: NSEvent) { refreshHover() }
    override func mouseExited(with event: NSEvent) { setHovered(false, animated: true) }

    func refreshHover() {
        guard let window, window.isKeyWindow, !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty else {
            setHovered(false, animated: false); return
        }
        setHovered(visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)), animated: true)
    }

    func setHovered(_ hovered: Bool, animated: Bool) {
        isHovered = hovered
        updateFeedback(animated: animated)
    }

    func updateFeedback(animated: Bool) {
        let target: Float = (isHovered || isShowingMenu) && !isSelected ? 1 : 0
        let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard hoverLayer.opacity != target else {
            if !shouldAnimate { hoverLayer.removeAnimation(forKey: animationKey) }
            return
        }
        let current = hoverLayer.presentation()?.opacity ?? hoverLayer.opacity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        hoverLayer.opacity = target
        CATransaction.commit()
        hoverLayer.removeAnimation(forKey: animationKey)
        if shouldAnimate {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = current; animation.toValue = target
            animation.duration = target == 1 ? 0.12 : 0.16
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            hoverLayer.add(animation, forKey: animationKey)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); updateHoverColor()
    }
    private func updateHoverColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            hoverLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.055).cgColor
            CATransaction.commit()
        }
    }
    @objc private func displayOptionsChanged() { updateHoverColor(); updateFeedback(animated: false) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        if let window {
            center.addObserver(self, selector: #selector(keyWindowChanged), name: NSWindow.didResignKeyNotification, object: window)
            center.addObserver(self, selector: #selector(keyWindowChanged), name: NSWindow.didBecomeKeyNotification, object: window)
        }
        refreshHover()
    }
    @objc private func keyWindowChanged() { refreshHover() }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil { isShowingMenu = false; setHovered(false, animated: false) }
        super.viewWillMove(toSuperview: newSuperview)
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { isShowingMenu = false; setHovered(false, animated: false) }
        super.viewWillMove(toWindow: newWindow)
    }
}
