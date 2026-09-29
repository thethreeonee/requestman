import AppKit
import RequestmanCore

typealias RecordColumn = RequestLogStandardColumn
extension RequestLogStandardColumn {
    var identifier: NSUserInterfaceItemIdentifier { .init(rawValue) }
}

@MainActor
enum RequestLogDisplayOptionsMenu {
    static func make(options: RequestLogDisplayOptions, allowLAN: Bool,
                     onChange: @escaping (RequestLogDisplayOptions) -> Void,
                     editColumn: @escaping (RequestLogExtraColumn?) -> Void) -> NSMenu {
        let menu = NSMenu(title: "显示选项")
        menu.autoenablesItems = false
        for column in RecordColumn.allCases {
            let item = RequestActionsMenu.item(column.title) {
                var next = options
                if next.columns.contains(column) { next.columns.remove(column) }
                else { next.columns.insert(column) }
                onChange(next)
            }
            item.state = options.columns.contains(column) ? .on : .off
            item.isEnabled = column != .device || allowLAN
            if column == .device && !allowLAN { item.toolTip = "开启允许局域网设备连接后可显示" }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for column in options.extraColumns {
            let title = (column.displayTitle.isEmpty ? column.field.title : column.displayTitle) + " · " + column.stage.title
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.state = column.isEnabled ? .on : .off
            item.toolTip = column.summary
            let submenu = NSMenu(title: title); submenu.autoenablesItems = false
            let visible = RequestActionsMenu.item("显示此字段") {
                var next = options
                guard let index = next.extraColumns.firstIndex(where: { $0.id == column.id }) else { return }
                next.extraColumns[index].isEnabled.toggle()
                onChange(next)
            }
            visible.state = column.isEnabled ? .on : .off
            submenu.addItem(visible)
            let merge = NSMenuItem(title: "合并显示到", action: nil, keyEquivalent: "")
            let targets = NSMenu(title: "合并显示到")
            let destinations: [String?] = [nil] + options.visibleColumnIDs(allowLAN: allowLAN)
                .filter { $0 != column.identifier }.map { Optional($0) }
            for destination in destinations {
                let choice = RequestActionsMenu.item(destination.map { options.title(forColumnID: $0) } ?? "独立列") {
                    var next = options
                    guard let index = next.extraColumns.firstIndex(where: { $0.id == column.id }) else { return }
                    next.extraColumns[index].mergedInto = destination
                    onChange(next)
                }
                choice.state = (destination == nil ? options.displayColumnID(for: column) == column.identifier
                    : column.mergedInto != nil && options.displayColumnID(for: column) == destination) ? .on : .off
                targets.addItem(choice)
            }
            merge.submenu = targets
            submenu.addItem(merge)
            submenu.addItem(RequestActionsMenu.item("编辑…") { editColumn(column) })
            submenu.addItem(RequestActionsMenu.item("删除") {
                var next = options
                next.extraColumns.removeAll { $0.id == column.id }
                next.columnOrder = next.orderedColumnIDs
                onChange(next)
            })
            item.submenu = submenu
            menu.addItem(item)
        }
        if !options.extraColumns.isEmpty { menu.addItem(.separator()) }
        menu.addItem(RequestActionsMenu.item("添加额外字段…") { editColumn(nil) })
        return menu
    }
}

@MainActor
final class RequestLogExtraColumnEditor: NSViewController {
    private var draft: RequestLogExtraColumn
    private let isNew: Bool
    private let onSave: (RequestLogExtraColumn) -> Void
    private let field = NSPopUpButton(frame: .zero, pullsDown: false)
    private let stage = NSPopUpButton(frame: .zero, pullsDown: false)
    private lazy var name = ActionComboBox(draft.name, placeholder: "字段名", onChange: { [weak self] in
        self?.draft.name = $0; self?.validate()
    })
    private lazy var customTitle = ActionTextField(draft.title, placeholder: "留空使用字段名") { [weak self] in self?.draft.title = $0 }
    private let nameLabel = NativeUI.label("名称", size: 12, secondary: true)
    private let error = NativeUI.label("", size: 12, secondary: true)
    private var contentStack: NSStackView?
    private lazy var save = ActionButton(title: isNew ? "添加" : "保存") { [weak self] in self?.submit() }

    init(column: RequestLogExtraColumn?, onSave: @escaping (RequestLogExtraColumn) -> Void) {
        draft = column ?? .init(); isNew = column == nil; self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        view = NSView()
        field.addItems(withTitles: RequestLogExtraColumn.Field.allCases.map(\.title))
        field.selectItem(at: RequestLogExtraColumn.Field.allCases.firstIndex(of: draft.field) ?? 0)
        field.target = self; field.action = #selector(changeField)
        stage.target = self; stage.action = #selector(changeStage)
        field.setAccessibilityLabel("字段类型"); stage.setAccessibilityLabel("阶段")
        customTitle.setAccessibilityLabel("字段标题")
        customTitle.onSubmit = { [weak self] in self?.submit() }
        let cancel = ActionButton(title: "取消") { [weak self] in self?.dismiss(nil) }
        cancel.keyEquivalent = "\u{1b}"
        let actions = NativeUI.stack([cancel, save], vertical: false)
        let stack = NativeUI.stack([
            NativeUI.label(isNew ? "添加额外字段" : "编辑额外字段", size: 18, weight: .semibold),
            NativeUI.label("字段类型", size: 12, secondary: true), field,
            NativeUI.label("阶段", size: 12, secondary: true), stage,
            nameLabel, name, NativeUI.label("字段标题（可选）", size: 12, secondary: true), customTitle, error, actions
        ], spacing: 8)
        NativeUI.pin(stack, to: view, insets: NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20))
        for control in [field, stage, name, customTitle, error] {
            control.widthAnchor.constraint(equalToConstant: 340).isActive = true
        }
        contentStack = stack
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        updateFields()
    }
    private func updateFields() {
        if !draft.field.stages.contains(draft.stage) { draft.stage = draft.field.stages[0] }
        stage.removeAllItems(); stage.addItems(withTitles: draft.field.stages.map(\.title))
        stage.selectItem(at: draft.field.stages.firstIndex(of: draft.stage) ?? 0)
        nameLabel.isHidden = !draft.field.needsName; name.isHidden = !draft.field.needsName
        nameLabel.stringValue = draft.field == .header ? "Header 名称" : "查询参数名"
        name.setAccessibilityLabel(nameLabel.stringValue)
        name.placeholderString = draft.field == .header ? "选择或输入 Header" : "例如 page、keyword"
        name.setSuggestions(draft.field == .header ? HeaderNameField.suggestions : [])
        validate()
        if let contentStack {
            let size = NSSize(width: 380, height: ceil(contentStack.fittingSize.height) + 40)
            if preferredContentSize != size { preferredContentSize = size }
            if view.frame.size != size { view.setFrameSize(size) }
        }
    }
    private func validate() { error.stringValue = draft.validationError ?? " "; save.isEnabled = draft.validationError == nil }
    @objc private func changeField() {
        guard RequestLogExtraColumn.Field.allCases.indices.contains(field.indexOfSelectedItem) else { return }
        draft.field = RequestLogExtraColumn.Field.allCases[field.indexOfSelectedItem]; updateFields()
    }
    @objc private func changeStage() {
        guard draft.field.stages.indices.contains(stage.indexOfSelectedItem) else { return }
        draft.stage = draft.field.stages[stage.indexOfSelectedItem]; validate()
    }
    private func submit() {
        guard view.window?.makeFirstResponder(nil) == true, draft.validationError == nil else { return }
        onSave(draft); dismiss(nil)
    }
}
