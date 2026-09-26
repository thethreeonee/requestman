import AppKit
import QuartzCore

/// AppKit retains disclosure hit testing, selection, keyboard navigation and accessibility.
@MainActor final class ProjectOutlineView: NSOutlineView {
    var contextMenu: (Int) -> NSMenu? = { _ in nil }
    var animatesDisclosure = true
    private var changingDisclosure = false
    private var disappearingRows: [CALayer] = []
    private var transitionGeneration = 0
    static let disclosureDuration: TimeInterval = 0.18

    override init(frame: NSRect) {
        super.init(frame: frame)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func reloadData() {
        cancelDisclosureAnimations()
        super.reloadData()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { cancelDisclosureAnimations() }
        super.viewWillMove(toWindow: newWindow)
    }

    @objc private func displayOptionsChanged() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { cancelDisclosureAnimations() }
    }

    private func cancelDisclosureAnimations() {
        transitionGeneration += 1
        disappearingRows.forEach { $0.removeFromSuperlayer() }
        disappearingRows.removeAll()
        guard numberOfColumns > 0 else { return }
        enumerateAvailableRowViews { rowView, row in
            rowView.layer?.removeAnimation(forKey: "sidebar.rowPosition")
            rowView.layer?.removeAnimation(forKey: "sidebar.rowOpacity")
            (self.disclosureButton(at: row) as? ProjectDisclosureButton)?.finishRotation()
        }
    }

    override func expandItem(_ item: Any?, expandChildren: Bool) {
        changeDisclosure(item, expanding: true) { super.expandItem(item, expandChildren: expandChildren) }
    }

    override func collapseItem(_ item: Any?, collapseChildren: Bool) {
        changeDisclosure(item, expanding: false) { super.collapseItem(item, collapseChildren: collapseChildren) }
    }

    private func changeDisclosure(_ item: Any?, expanding: Bool, change: () -> Void) {
        // Mutate the native outline exactly once. Never send an animator proxy back
        // through this override or defer a structural change to an animation callback.
        guard !changingDisclosure, animatesDisclosure, window != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let item = item as? NSObject, isItemExpanded(item) != expanding else {
            if !changingDisclosure, !animatesDisclosure || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                cancelDisclosureAnimations()
            }
            change(); return
        }
        changingDisclosure = true
        defer { changingDisclosure = false }
        transitionGeneration += 1
        let generation = transitionGeneration
        disappearingRows.forEach { $0.removeFromSuperlayer() }
        disappearingRows.removeAll()
        layoutSubtreeIfNeeded()
        var positions: [NSObject: CGPoint] = [:]
        let parentRow = row(forItem: item)
        let parentLevel = level(forItem: item)
        var childEnd = parentRow + 1
        while childEnd < numberOfRows && level(forRow: childEnd) > parentLevel { childEnd += 1 }
        enumerateAvailableRowViews { rowView, row in
            guard row >= 0, let rowItem = self.item(atRow: row) as? NSObject else { return }
            rowView.wantsLayer = true
            positions[rowItem] = rowView.layer?.presentation()?.position ?? rowView.layer?.position
            if !expanding, row > parentRow, row < childEnd,
               rowView.frame.intersects(self.visibleRect),
               let bitmap = rowView.bitmapImageRepForCachingDisplay(in: rowView.bounds) {
                rowView.cacheDisplay(in: rowView.bounds, to: bitmap)
                let snapshot = CALayer()
                snapshot.name = "sidebar.disappearingRow"
                snapshot.contents = bitmap.cgImage
                snapshot.contentsScale = self.window?.backingScaleFactor ?? 2
                snapshot.frame = rowView.frame
                self.disappearingRows.append(snapshot)
            }
        }
        let previousAngle = (disclosureButton(at: parentRow) as? ProjectDisclosureButton)?.visibleAngle
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            change()
            let visibleRows = rows(in: visibleRect)
            if visibleRows.location != NSNotFound {
                for row in visibleRows.location..<min(NSMaxRange(visibleRows), numberOfRows) {
                    _ = rowView(atRow: row, makeIfNecessary: true)
                }
            }
            layoutSubtreeIfNeeded()
        }
        guard isItemExpanded(item) == expanding else {
            disappearingRows.removeAll(); return
        }
        (disclosureButton(at: row(forItem: item)) as? ProjectDisclosureButton)?
            .updateRotation(animated: true, from: previousAngle)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.transitionGeneration == generation else { return }
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                self.cancelDisclosureAnimations(); return
            }
            self.animateDisclosure(positions: positions, generation: generation)
        }
    }

    private func animateDisclosure(positions: [NSObject: CGPoint], generation: Int) {
        enumerateAvailableRowViews { rowView, row in
            guard row >= 0, let rowItem = self.item(atRow: row) as? NSObject,
                  let layer = rowView.layer else { return }
            let destination = layer.position
            let origin = positions[rowItem] ?? CGPoint(x: destination.x, y: destination.y - 8)
            if origin != destination {
                self.animate(layer, key: "sidebar.rowPosition", path: "position", from: NSValue(point: origin), to: NSValue(point: destination))
            }
            if positions[rowItem] == nil {
                self.animate(layer, key: "sidebar.rowOpacity", path: "opacity", from: 0, to: 1)
            }
        }
        for snapshot in disappearingRows {
            let startY = snapshot.position.y
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer?.addSublayer(snapshot)
            snapshot.opacity = 0
            snapshot.position.y = startY - 8
            CATransaction.commit()
            animate(snapshot, key: "sidebar.rowOpacity", path: "opacity", from: 1, to: 0)
            animate(snapshot, key: "sidebar.rowPosition", path: "position.y", from: startY, to: snapshot.position.y)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.disclosureDuration) { [weak self] in
            guard let self, self.transitionGeneration == generation else { return }
            self.disappearingRows.forEach { $0.removeFromSuperlayer() }
            self.disappearingRows.removeAll()
        }
    }

    override func makeView(withIdentifier identifier: NSUserInterfaceItemIdentifier, owner: Any?) -> NSView? {
        guard identifier == NSOutlineView.disclosureButtonIdentifier else {
            return super.makeView(withIdentifier: identifier, owner: owner)
        }
        // Apple's documented extension point: retain the native disclosure action.
        let native = super.makeView(withIdentifier: identifier, owner: owner) as? NSButton
        let button = ProjectDisclosureButton()
        button.identifier = identifier
        button.target = native?.target
        button.action = native?.action
        button.outline = self
        return button
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

    private func animate(_ layer: CALayer, key: String, path: String, from: Any, to: Any) {
        let animation = CABasicAnimation(keyPath: path)
        animation.fromValue = from; animation.toValue = to
        animation.duration = Self.disclosureDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: key)
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

/// One SF Symbol for both states prevents native alternate-image geometry from
/// moving the chevron. The NSButton's target/action and hit testing stay native.
@MainActor final class ProjectDisclosureButton: NSButton {
    weak var outline: ProjectOutlineView?
    private var targetAngle: CGFloat = 0
    private var hasInitialState = false
    private static let rotationKey = "sidebar.disclosureRotation"

    override init(frame: NSRect) {
        super.init(frame: frame)
        title = ""
        isBordered = false
        setButtonType(.onOff)
        imagePosition = .imageOnly
        let symbol = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        image = symbol; alternateImage = symbol
        wantsLayer = true
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityLabel("展开或收起项目")
    }
    required init?(coder: NSCoder) { nil }

    override var state: NSControl.StateValue {
        didSet { updateRotation(animated: oldValue != state) }
    }

    override func layout() {
        super.layout()
        // The frame is a fixed square in either state. Keep its center transform
        // in sync with AppKit layout without replacing an in-flight animation.
        setModelAngle(targetAngle)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateSelectionAppearance()
    }

    func updateSelectionAppearance() {
        let row = superview as? NSTableRowView
        contentTintColor = row?.isSelected == true && row?.isEmphasized == true
            ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }

    func finishRotation() {
        layer?.removeAnimation(forKey: Self.rotationKey)
        setModelAngle(targetAngle)
    }

    var visibleAngle: CGFloat {
        layer?.presentation()?.value(forKeyPath: "transform.rotation.z") as? CGFloat ?? targetAngle
    }

    func updateRotation(animated: Bool, from previousAngle: CGFloat? = nil) {
        guard let layer else { return }
        setAccessibilityExpanded(state == .on)
        let next: CGFloat = state == .on ? .pi / 2 : 0
        let previous = previousAngle ?? visibleAngle
        let shouldAnimate = animated && hasInitialState && window != nil
            && outline?.animatesDisclosure == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        hasInitialState = true
        targetAngle = next
        setModelAngle(next)
        if shouldAnimate {
            // A single transform interpolation also interpolates its translation,
            // making an off-origin pivot drift. Sample the centered rotation so the
            // visible glyph stays centered throughout, not only at the endpoints.
            let animation = CAKeyframeAnimation(keyPath: "transform")
            animation.values = (0...32).map { index in
                NSValue(caTransform3D: centeredRotation(previous + (next - previous) * CGFloat(index) / 32))
            }
            animation.duration = ProjectOutlineView.disclosureDuration
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(animation, forKey: Self.rotationKey)
        } else if animated { finishRotation() }
        // Repeated identical state assignments during layout retain the animation.
    }

    private func setModelAngle(_ angle: CGFloat) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.transform = centeredRotation(angle)
        CATransaction.commit()
    }

    private func centeredRotation(_ angle: CGFloat) -> CATransform3D {
        guard let layer else { return CATransform3DIdentity }
        let pivot = CGPoint(x: layer.bounds.midX - layer.bounds.width * layer.anchorPoint.x,
                            y: layer.bounds.midY - layer.bounds.height * layer.anchorPoint.y)
        var transform = CATransform3DMakeTranslation(pivot.x, pivot.y, 0)
        transform = CATransform3DRotate(transform, angle, 0, 0, 1)
        return CATransform3DTranslate(transform, -pivot.x, -pivot.y, 0)
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
            suffix.trailingAnchor.constraint(equalTo: menuSlot.leadingAnchor, constant: -8),
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
        // Keep menus legible and operable for disabled projects and workflows.
        self.title.alphaValue = enabled ? 1 : 0.55
        icon.alphaValue = enabled ? 1 : 0.55
        moreButton.toolTip = "\(title)的更多操作"
        moreButton.setAccessibilityLabel("\(title)的更多操作")
        updateSelectionAppearance()
    }

    func showActions(_ visible: Bool) { moreButton.isHidden = !visible }

    func updateSelectionAppearance() {
        let emphasized = (superview as? NSTableRowView).map { $0.isSelected && $0.isEmphasized } ?? false
        icon.contentTintColor = emphasized ? .alternateSelectedControlTextColor : .controlAccentColor
        suffix.textColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }

    @objc private func openMenu() { showMenu?(moreButton) }
}

/// Only the explicitly requested hover feedback is layered; AppKit draws selection and focus.
@MainActor final class ProjectSidebarRowView: NSTableRowView {
    private let hoverLayer = CALayer()
    private var hoverTrackingArea: NSTrackingArea?
    private(set) var isHovered = false
    var isShowingMenu = false { didSet { updateFeedback(animated: false) } }
    private static let animationKey = "sidebar.hoverOpacity"

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        hoverLayer.name = "sidebar.hoverBackground"
        hoverLayer.opacity = 0
        hoverLayer.cornerRadius = 6
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
        hoverLayer.frame = bounds.insetBy(dx: 10, dy: 1)
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

    private func updateFeedback(animated: Bool) {
        let cell = numberOfColumns > 0 ? view(atColumn: 0) as? RulesSidebarCell : nil
        cell?.showActions(isHovered || isSelected || isShowingMenu)
        cell?.updateSelectionAppearance()
        subviews.compactMap { $0 as? ProjectDisclosureButton }.forEach { $0.updateSelectionAppearance() }
        let target: Float = (isHovered || isShowingMenu) && !isSelected ? 1 : 0
        let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard hoverLayer.opacity != target else {
            if !shouldAnimate { hoverLayer.removeAnimation(forKey: Self.animationKey) }
            return
        }
        let current = hoverLayer.presentation()?.opacity ?? hoverLayer.opacity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        hoverLayer.opacity = target
        CATransaction.commit()
        hoverLayer.removeAnimation(forKey: Self.animationKey)
        if shouldAnimate {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = current; animation.toValue = target
            animation.duration = target == 1 ? 0.12 : 0.16
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            hoverLayer.add(animation, forKey: Self.animationKey)
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
