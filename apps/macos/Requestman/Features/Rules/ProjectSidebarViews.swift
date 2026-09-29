import AppKit

/// AppKit retains disclosure hit testing, selection, keyboard navigation and accessibility.
@MainActor final class ProjectOutlineView: NSOutlineView {
    var contextMenu: (Int) -> NSMenu? = { _ in nil }
    override func shouldCollapseAutoExpandedItems(forDeposited deposited: Bool) -> Bool {
        // Keep the destination visible after a move; cancelled drags restore it.
        !deposited
    }
    func setExpanded(_ expanded: Bool, for item: Any, animated: Bool) {
        guard isItemExpanded(item) != expanded else { return }
        // AppKit owns row insertion/removal and disclosure state together. Do not
        // animate backing layers or retain snapshots of rows that it may reuse.
        let shouldAnimate = animated && window != nil
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = shouldAnimate ? 0.18 : 0
            let target = shouldAnimate ? animator() : self
            if expanded { target.expandItem(item) }
            else { target.collapseItem(item) }
        }
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        guard frame.width > 0, row >= 0 else { return frame }
        let content = frameOfCell(atColumn: 0, row: row)
        frame = NSRect(x: content.minX - 26, y: content.midY - 10, width: 20, height: 20)
        return frame
    }

    func disclosureButton(at row: Int) -> NSButton? {
        guard row >= 0, let rowView = rowView(atRow: row, makeIfNecessary: false) else { return nil }
        return rowView.subviews.compactMap { $0 as? NSButton }.first {
            $0.identifier == NSOutlineView.disclosureButtonIdentifier
        }
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        // Native child indentation is 20pt; parent icon + gap occupies 24pt.
        // Inset the entire content group so the disclosure has room inside the
        // selection background; retain the 4pt correction for aligned titles.
        let padding: CGFloat = level(forRow: row) > 0 ? 20 : 16
        frame.origin.x += padding
        frame.size.width = max(0, frame.width - padding)
        return frame
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menu = contextMenu(row(at: convert(event.locationInWindow, from: nil)))
        guard menu != nil else { return nil }
        return super.menu(for: event)
    }
}

@MainActor final class RulesSidebarCell: NSTableCellView {
    private let title = NativeUI.label("")
    private let icon = NSImageView()
    private let suffix = NativeUI.label("", size: 11, secondary: true)
    private let menuSlot = NSView()
    private let moreButton = NSButton()
    private var titleLeading: NSLayoutConstraint!
    var showMenu: ((NSButton) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        textField = title
        title.lineBreakMode = .byTruncatingMiddle
        title.identifier = .init("rules.sidebarTitle")
        icon.identifier = .init("rules.sidebarIcon")
        suffix.identifier = .init("rules.sidebarCount")
        suffix.alignment = .right
        moreButton.identifier = .init("rules.sidebarMore")
        moreButton.title = ""
        moreButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "更多操作")
        moreButton.imagePosition = .imageOnly
        moreButton.bezelStyle = .inline
        moreButton.isBordered = false
        moreButton.target = self; moreButton.action = #selector(openMenu)
        moreButton.isHidden = true
        for child in [icon, title, suffix, menuSlot] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NativeUI.pin(moreButton, to: menuSlot)
        titleLeading = title.leadingAnchor.constraint(equalTo: leadingAnchor)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            titleLeading, title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(equalTo: suffix.leadingAnchor, constant: -8),
            suffix.centerYAnchor.constraint(equalTo: centerYAnchor), suffix.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
            suffix.trailingAnchor.constraint(equalTo: menuSlot.trailingAnchor, constant: -4),
            menuSlot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            menuSlot.centerYAnchor.constraint(equalTo: centerYAnchor),
            menuSlot.widthAnchor.constraint(equalToConstant: 24), menuSlot.heightAnchor.constraint(equalToConstant: 24)
        ])
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        suffix.setContentHuggingPriority(.required, for: .horizontal)
        suffix.setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { nil }

    func configure(title: String, symbol: String?, suffix: String, enabled: Bool, project: Bool) {
        self.title.stringValue = title; self.title.toolTip = title
        self.title.font = .systemFont(ofSize: 13, weight: project ? .medium : .regular)
        icon.image = project ? NSImage(systemSymbolName: symbol ?? "folder", accessibilityDescription: nil) : nil
        if project && icon.image == nil { icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil) }
        icon.isHidden = !project
        titleLeading.constant = project ? 24 : 0
        self.suffix.stringValue = suffix
        // Dim the entire content, including the status marker, even when AppKit
        // updates the selected row's text appearance. Menus remain operable.
        alphaValue = enabled ? 1 : 0.45
        moreButton.toolTip = "\(title)的更多操作"
        moreButton.setAccessibilityLabel("\(title)的更多操作")
        updateSelectionAppearance()
    }

    func showActions(_ visible: Bool) {
        moreButton.isHidden = !visible
        suffix.isHidden = visible
    }

    func updateSelectionAppearance() {
        let emphasized = (superview as? NSTableRowView).map { $0.isSelected && $0.isEmphasized } ?? false
        icon.contentTintColor = emphasized ? .alternateSelectedControlTextColor : .controlAccentColor
        suffix.textColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }

    @objc private func openMenu() { showMenu?(moreButton) }
}

/// AppKit draws sidebar selection and focus; shared hover also reveals row actions.
@MainActor final class ProjectSidebarRowView: HoverTableRowView {
    override var hoverLayerPrefix: String { "sidebar" }

    override func updateFeedback(animated: Bool) {
        let cell = numberOfColumns > 0 ? view(atColumn: 0) as? RulesSidebarCell : nil
        cell?.showActions(isHovered || isSelected || isShowingMenu)
        cell?.updateSelectionAppearance()
        super.updateFeedback(animated: animated)
    }
}
