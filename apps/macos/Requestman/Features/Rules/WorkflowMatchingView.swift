import AppKit
import RequestmanCore

@MainActor enum MatchingControls {
    static func glass(_ button: NSButton, circle: Bool = false) {
        if #available(macOS 26.0, *) { button.bezelStyle = .glass; button.borderShape = circle ? .circle : .capsule }
        button.controlSize = .regular
    }
    static func spacer() -> NSView {
        let view = NSView(); view.setContentHuggingPriority(.defaultLow, for: .horizontal); return view
    }
    static func disclosure(_ action: @escaping () -> Void) -> ActionButton {
        let button = ActionButton(title: "", action: action)
        button.setButtonType(.pushOnPushOff); button.bezelStyle = .disclosure; button.state = .on
        button.setAccessibilityLabel("展开或收起匹配条件")
        return button
    }
    static func remove(_ action: @escaping () -> Void) -> ActionButton {
        let button = ActionButton(title: "", action: action)
        button.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "移除")
        button.setAccessibilityLabel("移除条件"); button.toolTip = "移除条件"
        glass(button, circle: true)
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }
}

/// Stable row identities preserve field editor focus, selection and IME composition during observation refreshes.
@MainActor final class WorkflowMatchingView: NSView {
    private let model: WorkspaceModel
    private var workflowID: UUID?
    private var groupView: MatchingGroupView?
    private var collapsed: Set<UUID> = []
    init(model: WorkspaceModel) { self.model = model; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    func refresh() {
        guard let workflow = model.workflow else { return }
        if workflowID != workflow.id {
            groupView?.removeFromSuperview()
            workflowID = workflow.id
            let group = MatchingGroupView(root: true, depth: 0)
            group.changed = { [weak self] id, action in
                guard let self, model.loaded, var workflow = model.workflow else { return }
                var tree = workflow.matchConditions
                tree.update(id, action)
                workflow.matchConditions = tree
                model.updateWorkflow(workflow)
            }
            group.toggleCollapsed = { [weak self] id in
                guard let self else { return }
                if !collapsed.insert(id).inserted { collapsed.remove(id) }
                refresh()
            }
            group.test = { [weak self] in
                guard let self else { return }
                window?.makeFirstResponder(nil)
                guard let workflow = model.workflow, let controller = window?.contentViewController else { return }
                controller.presentAsSheet(WorkflowMatchTestViewController(workflow: workflow))
            }
            groupView = group; NativeUI.pin(group, to: self)
        }
        groupView?.refresh(workflow.matchConditions, editable: model.loaded, collapsed: collapsed)
    }
}

@MainActor private final class MatchingGroupView: NSView {
    var changed: ((UUID, (inout WorkflowMatchGroup) -> Void) -> Void)?
    var toggleCollapsed: ((UUID) -> Void)?
    var test: (() -> Void)?
    private let root: Bool
    private let depth: Int
    private var group = WorkflowMatchGroup()
    private var rows: [UUID: MatchingConditionView] = [:]
    private var children: [UUID: MatchingGroupView] = [:]
    private var structure: [UUID] = []
    private let body = NativeUI.stack([], spacing: 8)
    private let summary = NativeUI.label("", size: 11, secondary: true)
    private let error = NativeUI.label("", size: 11)
    private let count = NativeUI.label("", size: 11, secondary: true)
    private lazy var disclosure = MatchingControls.disclosure { [weak self] in
        guard let self else { return }; window?.makeFirstResponder(nil); toggleCollapsed?(group.id)
    }
    private lazy var enabled: ActionButton = ActionButton(title: "") { [weak self] in
        guard let self else { return }; changed?(group.id) { $0.enabled = self.enabled.state == .on }
    }
    private lazy var mode = ActionPopUpButton(items: WorkflowMatchGroup.Mode.allCases.map(\.title)) { [weak self] index in
        guard let self else { return }; changed?(group.id) { $0.mode = WorkflowMatchGroup.Mode.allCases[index] }
    }
    private lazy var add = ActionButton(title: "添加条件") { [weak self] in
        guard let self else { return }; changed?(group.id) { $0.conditions.append(MatchCondition()) }
    }
    private lazy var addGroup = ActionButton(title: "添加条件组") { [weak self] in
        guard let self else { return }; changed?(group.id) { $0.groups.append(WorkflowMatchGroup(mode: .any, conditions: [MatchCondition(field: .host, operation: .equals)])) }
    }
    private lazy var remove = MatchingControls.remove { [weak self] in self?.removeGroup?() }
    private var removeGroup: (() -> Void)?
    private lazy var testButton = ActionButton(title: "测试匹配") { [weak self] in self?.test?() }
    private let content = NativeUI.stack([], spacing: 10)
    init(root: Bool, depth: Int) {
        self.root = root; self.depth = depth
        super.init(frame: .zero)
        identifier = .init(root ? "rules.matching" : "rules.conditionGroup")
        enabled.setButtonType(.switch); enabled.setAccessibilityLabel("启用条件组")
        MatchingControls.glass(mode)
        mode.setAccessibilityLabel("条件组合方式"); mode.identifier = .init("rules.matchMode")
        mode.widthAnchor.constraint(equalToConstant: 85).isActive = true
        for button in [add, addGroup, testButton] { MatchingControls.glass(button) }
        for button in [add, addGroup] { button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil); button.imagePosition = .imageLeading }
        add.identifier = .init("rules.addCondition"); addGroup.identifier = .init("rules.addConditionGroup")
        testButton.identifier = .init("rules.testMatch")
        disclosure.identifier = .init(root ? "rules.collapseMatching" : "rules.collapseGroup")
        let heading: NSStackView
        if root {
            heading = NativeUI.stack([disclosure, NativeUI.label("匹配条件", size: 15, weight: .semibold), count, MatchingControls.spacer(), testButton], vertical: false, spacing: 8)
        } else {
            heading = NativeUI.stack([disclosure, enabled, NativeUI.label("条件组", weight: .medium), count, MatchingControls.spacer(), remove], vertical: false, spacing: 6)
        }
        let logic = NativeUI.stack([NativeUI.label("满足以下"), mode, NativeUI.label("条件"), MatchingControls.spacer()], vertical: false, spacing: 8)
        let footer = NativeUI.stack([add, addGroup, MatchingControls.spacer()], vertical: false, spacing: 8)
        // Keep arbitrary imported nesting readable without repeatedly consuming horizontal space.
        addGroup.toolTip = "添加独立选择全部或任一的条件组"
        content.addArrangedSubview(logic); content.addArrangedSubview(body); content.addArrangedSubview(footer)
        for child in content.arrangedSubviews { child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        error.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summary.maximumNumberOfLines = 1; summary.lineBreakMode = .byTruncatingTail
        error.textColor = .systemRed; error.maximumNumberOfLines = 0; error.lineBreakMode = .byWordWrapping
        let stack = NativeUI.stack([heading, content, summary, error], spacing: 10)
        for child in stack.arrangedSubviews { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        let box = NSBox(); box.titlePosition = .noTitle; box.contentViewMargins = .zero
        box.boxType = .custom; box.borderWidth = 1; box.borderColor = .separatorColor
        box.fillColor = .clear; box.cornerRadius = 8
        box.contentView = NSView()
        NativeUI.pin(box, to: self)
        NativeUI.pin(box.contentView!, to: box)
        NativeUI.pin(stack, to: box.contentView!, insets: NSEdgeInsets(top: 12, left: root ? 12 : 8, bottom: 12, right: root ? 12 : 8))
    }
    required init?(coder: NSCoder) { nil }
    func refresh(_ group: WorkflowMatchGroup, editable: Bool, collapsed: Set<UUID>) {
        self.group = group
        let ids = group.conditions.map(\.id) + group.groups.map(\.id)
        if structure != ids {
            structure = ids
            for view in body.arrangedSubviews { body.removeArrangedSubview(view); view.removeFromSuperview() }
            rows = rows.filter { key, _ in group.conditions.contains { $0.id == key } }
            children = children.filter { key, _ in group.groups.contains { $0.id == key } }
            for item in group.conditions {
                let row = rows[item.id] ?? MatchingConditionView()
                row.changed = { [weak self] action in
                    guard let self else { return }
                    changed?(self.group.id) { tree in
                        guard let index = tree.conditions.firstIndex(where: { $0.id == item.id }) else { return }
                        action(&tree.conditions[index])
                    }
                }
                row.remove = { [weak self] in
                    guard let self else { return }; changed?(self.group.id) { $0.conditions.removeAll { $0.id == item.id } }
                }
                rows[item.id] = row; body.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
            }
            for item in group.groups {
                let child = children[item.id] ?? MatchingGroupView(root: false, depth: depth + 1)
                child.changed = { [weak self] id, action in self?.changed?(id, action) }
                child.toggleCollapsed = { [weak self] id in self?.toggleCollapsed?(id) }
                child.removeGroup = { [weak self] in
                    guard let self else { return }; changed?(self.group.id) { $0.groups.removeAll { $0.id == item.id } }
                }
                children[item.id] = child; body.addArrangedSubview(child)
                child.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
            }
        }
        enabled.state = group.enabled ? .on : .off; enabled.isEnabled = editable
        let active = editable && group.enabled
        mode.selectItem(at: group.mode == .all ? 0 : 1)
        for control in [mode, add, addGroup] as [NSControl] { control.isEnabled = active }
        remove.isEnabled = editable; testButton.isEnabled = editable
        for item in group.conditions { rows[item.id]?.refresh(item, editable: active) }
        for item in group.groups { children[item.id]?.refresh(item, editable: active, collapsed: collapsed) }
        content.isHidden = collapsed.contains(group.id)
        disclosure.state = content.isHidden ? .off : .on
        count.stringValue = "\(group.conditionCount) 个条件"
        summary.stringValue = group.summary; summary.toolTip = group.summary
        summary.isHidden = !content.isHidden
        error.stringValue = group.validationError ?? ""; error.isHidden = error.stringValue.isEmpty
    }
}

@MainActor private final class MatchingConditionView: NSView {
    var changed: (((inout MatchCondition) -> Void) -> Void)?
    var remove: (() -> Void)?
    private var item = MatchCondition()
    private lazy var enabled: ActionButton = ActionButton(title: "") { [weak self] in
        guard let self else { return }; changed? { $0.enabled = self.enabled.state == .on }
    }
    private lazy var field: ActionPopUpButton = ActionPopUpButton(items: MatchField.allCases.map(\.title)) { [weak self] index in
        guard let self else { return }
        changed? {
            $0.field = MatchField.allCases[index]
            if !$0.field.operators.contains($0.operation) { $0.operation = $0.field.operators[0] }
        }
    }
    private lazy var operation: ActionPopUpButton = ActionPopUpButton(items: []) { [weak self] index in
        guard let self else { return }; changed? { $0.operation = self.item.field.operators[index] }
    }
    private lazy var name = ActionTextField(placeholder: "名称") { [weak self] text in self?.changed? { $0.name = text } }
    private lazy var value = ActionTextField(placeholder: "匹配值") { [weak self] text in self?.changed? { $0.value = text } }
    private lazy var removeButton = MatchingControls.remove { [weak self] in self?.remove?() }
    private var arranged: [NSLayoutConstraint] = []
    private var layoutKey = ""
    private static let popupWidth: CGFloat = 125
    init() {
        super.init(frame: .zero)
        identifier = .init("rules.conditionRow")
        enabled.setButtonType(.switch); enabled.setAccessibilityLabel("启用匹配条件")
        MatchingControls.glass(field); MatchingControls.glass(operation)
        field.setAccessibilityLabel("匹配字段"); operation.setAccessibilityLabel("匹配运算符")
        name.setAccessibilityLabel("匹配名称"); value.setAccessibilityLabel("匹配值")
        for control in [enabled, field, name, operation, value, removeButton] as [NSControl] {
            addSubview(control); control.translatesAutoresizingMaskIntoConstraints = false
        }
        for input in [name, value] {
            input.cell?.usesSingleLineMode = true; input.cell?.isScrollable = true; input.cell?.wraps = false
            input.setContentHuggingPriority(.defaultLow, for: .horizontal)
            input.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        enabled.widthAnchor.constraint(equalToConstant: 20).isActive = true
        field.widthAnchor.constraint(equalToConstant: Self.popupWidth).isActive = true
        operation.widthAnchor.constraint(equalToConstant: Self.popupWidth).isActive = true
    }
    required init?(coder: NSCoder) { nil }
    func refresh(_ item: MatchCondition, editable: Bool) {
        self.item = item
        enabled.state = item.enabled ? .on : .off; enabled.isEnabled = editable; removeButton.isEnabled = editable
        field.selectItem(at: MatchField.allCases.firstIndex(of: item.field) ?? 0)
        let titles = item.field.operators.map(\.title)
        if operation.itemTitles != titles { operation.removeAllItems(); operation.addItems(withTitles: titles) }
        operation.selectItem(at: item.field.operators.firstIndex(of: item.operation) ?? 0)
        if name.stringValue != item.name { name.stringValue = item.name }
        if value.stringValue != item.value { value.stringValue = item.value }
        for control in [field, operation, name, value] as [NSControl] { control.isEnabled = editable && item.enabled }
        name.isHidden = !item.field.needsName; value.isHidden = !item.operation.needsValue
        value.placeholderString = [.oneOf, .notOneOf].contains(item.operation) ? "以逗号分隔，如 POST, PUT" : "匹配值"
        value.toolTip = item.validationError ?? (item.field == .path ? "不含查询参数，保留百分号编码；区分大小写" : "同名字段任一值满足正向条件；否定条件要求字段存在且所有值不满足")
        needsLayout = true
    }
    override func layout() {
        // Use the viewport as well as the row: a previous wide-row layout must not
        // impose its minimum width and prevent the first compact layout pass.
        var ancestor: NSView = self
        var availableWidth = bounds.width
        while let parent = ancestor.superview {
            if parent.bounds.width > 0 { availableWidth = min(availableWidth, parent.bounds.width) }
            ancestor = parent
        }
        // Reserve space only for visible controls, including a usable value input.
        let fixedControlsWidth: CGFloat = 20 + Self.popupWidth * 2 + 24 + 3 * 8
        let nameWidth: CGFloat = item.field.needsName ? 150 + 8 : 0
        let valueWidth: CGFloat = item.operation.needsValue ? 160 + 8 : 0
        let compact = availableWidth < fixedControlsWidth + nameWidth + valueWidth
        let key = "\(compact)-\(item.field.needsName)-\(item.operation.needsValue)"
        if layoutKey != key {
            layoutKey = key; NSLayoutConstraint.deactivate(arranged)
            var first: [NSView] = [enabled, field]
            var second: [NSView] = []
            if item.field.needsName { first.append(name) }
            if compact {
                // Keep the subject before its predicate when reading across rows.
                second.append(operation)
                if item.operation.needsValue { second.append(value) }
            } else {
                first.append(operation)
                if item.operation.needsValue { first.append(value) }
            }
            first.append(removeButton)
            let firstCenter = enabled.centerYAnchor
            let lineHeight = NativeInputMetrics.fieldHeight
            let lineSpacing: CGFloat = 8
            arranged = [enabled.leadingAnchor.constraint(equalTo: leadingAnchor), enabled.centerYAnchor.constraint(equalTo: topAnchor, constant: lineHeight / 2),
                        removeButton.trailingAnchor.constraint(equalTo: trailingAnchor),
                        heightAnchor.constraint(equalToConstant: second.isEmpty ? lineHeight : lineHeight * 2 + lineSpacing)]
            for view in first.dropFirst() { arranged.append(view.centerYAnchor.constraint(equalTo: firstCenter)) }
            for pair in zip(first, first.dropFirst()) {
                // Only text inputs stretch to fill the space before the remove button.
                if pair.1 === removeButton && pair.0 !== name && pair.0 !== value {
                    arranged.append(pair.1.leadingAnchor.constraint(greaterThanOrEqualTo: pair.0.trailingAnchor, constant: 8))
                } else {
                    arranged.append(pair.1.leadingAnchor.constraint(equalTo: pair.0.trailingAnchor, constant: 8))
                }
            }
            if !compact && item.field.needsName { arranged.append(name.widthAnchor.constraint(equalToConstant: 150)) }
            if let start = second.first, let end = second.last {
                arranged.append(start.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28))
                arranged.append(end === value
                    ? end.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32)
                    : end.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32))
                for view in second {
                    arranged.append(view.centerYAnchor.constraint(equalTo: topAnchor, constant: lineHeight * 1.5 + lineSpacing))
                }
                for pair in zip(second, second.dropFirst()) {
                    arranged.append(pair.1.leadingAnchor.constraint(equalTo: pair.0.trailingAnchor, constant: 8))
                }
            }
            NSLayoutConstraint.activate(arranged)
        }
        super.layout()
    }
}
