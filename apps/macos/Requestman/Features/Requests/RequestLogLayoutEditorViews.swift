import AppKit
import QuartzCore
import RequestmanCore

extension NSPasteboard.PasteboardType {
    static let requestLogColumn = Self("com.requestman.request-log-layout.column")
    static let requestLogLine = Self("com.requestman.request-log-layout.line")
    static let requestLogContent = Self("com.requestman.request-log-layout.content")
}

struct RequestLogLayoutDrag: Codable, Sendable {
    var owner: String
    var columnID: String? = nil
    var lineID: UUID? = nil
    var contentID: UUID? = nil

    var pasteboardString: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func pasteboardItem(for type: NSPasteboard.PasteboardType) -> NSPasteboardItem? {
        guard let string = pasteboardString else { return nil }
        let item = NSPasteboardItem()
        item.setString(string, forType: type)
        return item
    }
}

@MainActor
final class RequestLogColumnListCell: NSTableCellView {
    private let selectionBackground = NSBox()
    private let titleLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private var isColumnSelected = false

    init() {
        super.init(frame: .zero)
        selectionBackground.boxType = .custom
        selectionBackground.titlePosition = .noTitle
        selectionBackground.contentViewMargins = .zero
        selectionBackground.isTransparent = false
        selectionBackground.borderWidth = 0
        selectionBackground.cornerRadius = 8
        selectionBackground.fillColor = NSColor.white.blended(withFraction: 0.25, of: .systemBlue) ?? .white
        selectionBackground.setAccessibilityElement(false)
        addSubview(selectionBackground)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        summaryLabel.font = .systemFont(ofSize: 11)
        for label in [titleLabel, summaryLabel] {
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.cell?.usesSingleLineMode = true
            addSubview(label)
        }
        textField = titleLabel
        updateColors()
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    func setSelected(_ selected: Bool) {
        isColumnSelected = selected
        updateColors()
    }

    func configure(title: String, summary: String) {
        titleLabel.stringValue = title
        summaryLabel.stringValue = summary.isEmpty ? "尚未添加内容" : summary
        titleLabel.toolTip = title
        summaryLabel.toolTip = summary
        setAccessibilityLabel(title)
        setAccessibilityValue(summaryLabel.stringValue)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        selectionBackground.frame = NSRect(x: 2, y: 3, width: max(0, bounds.width - 4),
                                            height: max(0, bounds.height - 6))
        let inset = min(10, bounds.width / 2)
        let width = max(0, bounds.width - inset * 2)
        let top = (bounds.height - 36) / 2
        titleLabel.frame = NSRect(x: inset, y: top, width: width, height: 19)
        summaryLabel.frame = NSRect(x: inset, y: top + 21, width: width, height: 15)
    }

    private func updateColors() {
        selectionBackground.isHidden = !isColumnSelected
        titleLabel.textColor = .labelColor
        summaryLabel.textColor = isColumnSelected ? .labelColor : .secondaryLabelColor
    }
}

@MainActor
final class RequestLogLayoutTableView: NSTableView {
    var clearDropFeedback: () -> Void = { }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        if row >= 0,
           let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? RequestLogLayoutLineCell,
           cell.trackContentMouseDown(event) { return }
        super.mouseDown(with: event)
    }

    override func canDragRows(with rowIndexes: IndexSet, at mouseDownPoint: NSPoint) -> Bool {
        let row = row(at: mouseDownPoint)
        guard row >= 0,
              let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? RequestLogLayoutLineCell,
              cell.isLineDragArea(cell.convert(mouseDownPoint, from: self)) else { return false }
        return super.canDragRows(with: rowIndexes, at: mouseDownPoint)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        super.draggingExited(sender)
        clearDropFeedback()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        super.draggingEnded(sender)
        clearDropFeedback()
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { true }
}

@MainActor
final class RequestLogLayoutLineCell: NSTableCellView {
    var selectContent: (UUID) -> Void = { _ in }
    var addContent: (NSButton) -> Void = { _ in }
    var showActions: (NSButton) -> Void = { _ in }
    var contentActions: (UUID, NSButton) -> Void = { _, _ in }
    var dragBegan: (UUID, NSSize, CGFloat) -> Void = { _, _, _ in }
    var dragEnded: () -> Void = { }

    private let lineID: UUID
    private let owner: String
    private let lineGrip = RequestLogLineGripView()
    private let lineLabel = NSTextField(labelWithString: "")
    private let contentScroll = NSScrollView()
    private let contentDocument = FlippedView()
    private var contentControls: [RequestLogContentButton] = []
    private var draggingContentID: UUID?
    private var placeholderPosition: Int?
    private var placeholder: RequestLogContentButton?
    private var placeholderSize: NSSize?
    private static let positionAnimationKey = "requestLog.contentDrop.position"
    private static let opacityAnimationKey = "requestLog.contentDrop.opacity"
    private let addButton = NSButton()
    private let actionsButton = NSButton()

    init(line: RequestLogLayoutLine, index: Int, selectedID: UUID?, owner: String) {
        lineID = line.id
        self.owner = owner
        super.init(frame: .zero)
        lineLabel.stringValue = "第\(index + 1)行"
        lineLabel.font = .systemFont(ofSize: 12)
        lineLabel.textColor = .secondaryLabelColor
        lineLabel.maximumNumberOfLines = 1
        lineLabel.cell?.usesSingleLineMode = true
        lineGrip.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "拖动行")
        lineGrip.contentTintColor = .tertiaryLabelColor
        lineGrip.imageScaling = .scaleProportionallyDown
        lineGrip.setAccessibilityElement(false)
        contentScroll.documentView = contentDocument
        contentScroll.hasHorizontalScroller = true
        contentScroll.hasVerticalScroller = false
        contentScroll.autohidesScrollers = true
        contentScroll.borderType = .noBorder
        contentScroll.drawsBackground = false
        contentScroll.verticalScrollElasticity = .none
        contentScroll.horizontalScrollElasticity = .automatic
        contentDocument.wantsLayer = true

        configureIcon(addButton, symbol: "plus", label: "添加内容", action: #selector(addPressed(_:)))
        configureIcon(actionsButton, symbol: "ellipsis", label: "行操作", action: #selector(actionsPressed(_:)))
        for view in [lineGrip, lineLabel, contentScroll, addButton, actionsButton] { addSubview(view) }
        for content in line.contents {
            let control = RequestLogContentButton(content: content, lineID: line.id, owner: owner,
                                                  selected: content.id == selectedID)
            control.onSelect = { [weak self] in self?.selectContent($0) }
            control.onActions = { [weak self] in self?.contentActions($0, $1) }
            control.onDragBegin = { [weak self] in self?.dragBegan($0, $1, $2) }
            control.onDragEnd = { [weak self] in self?.dragEnded() }
            contentControls.append(control)
            contentDocument.addSubview(control)
        }
        setAccessibilityLabel(lineLabel.stringValue)
        setAccessibilityValue(line.contents.map(\.displayTitle).joined(separator: "，"))
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: max(18, contentScrollHeight) + 6)
    }

    private var contentHeight: CGFloat {
        max(addButton.intrinsicContentSize.height, actionsButton.intrinsicContentSize.height,
            contentControls.map(\.intrinsicContentSize.height).max() ?? 0,
            placeholderPosition == nil ? 0 : placeholderSize?.height ?? 0)
    }

    private var contentScrollHeight: CGFloat {
        let scrollerHeight = contentScroll.scrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: contentScroll.horizontalScroller?.controlSize ?? .regular, scrollerStyle: .legacy) : 0
        return contentHeight + scrollerHeight
    }

    func trackContentMouseDown(_ event: NSEvent) -> Bool {
        let point = contentScroll.contentView.convert(event.locationInWindow, from: nil)
        guard contentScroll.contentView.bounds.contains(point) else { return false }
        for control in contentControls where !control.isHidden {
            if control.bounds.contains(control.convert(event.locationInWindow, from: nil)) {
                control.mouseDown(with: event)
                return true
            }
        }
        return false
    }

    func isLineDragArea(_ point: NSPoint) -> Bool {
        bounds.contains(point) && point.x < contentScroll.frame.minX
    }

    func contentInsertionIndex(at center: NSPoint, dragging contentID: UUID, size: NSSize) -> Int {
        let point = contentDocument.convert(center, from: self)
        // Compare the held item's center with stable candidate slot centers.
        // Preview frames move aside and would make wide items stick to a slot.
        let remaining = contentControls.filter { $0.contentID != contentID }
        let sourceIndex = contentControls.firstIndex { $0.contentID == contentID }
        func originalIndex(_ slot: Int) -> Int {
            guard let sourceIndex, slot >= sourceIndex else { return slot }
            return slot + 1
        }
        var slotCenter: CGFloat = 4 + size.width / 2
        for (index, control) in remaining.enumerated() {
            let nextCenter = slotCenter + control.intrinsicContentSize.width + 6
            if point.x < (slotCenter + nextCenter) / 2 { return originalIndex(index) }
            slotCenter = nextCenter
        }
        return originalIndex(remaining.count)
    }

    func beginDragPreview(content: RequestLogLayoutContent, size: NSSize, at position: Int) {
        // Hide and replace the source in one layout, keeping the document's
        // width and scroll position from shrinking between these two changes.
        draggingContentID = content.id
        for control in contentControls { control.isHidden = control.contentID == content.id }
        showDropPreview(content: content, size: size, at: position)
    }

    func setDraggingContent(_ id: UUID?, animated: Bool = false) {
        guard draggingContentID != id else { return }
        draggingContentID = id
        for control in contentControls { control.isHidden = control.contentID == id }
        layoutContentControls(animated: animated)
    }

    func showDropPreview(content: RequestLogLayoutContent, size: NSSize, at position: Int) {
        let previousHeight = intrinsicContentSize.height
        let previousSlot = placeholderPosition.map(effectiveSlot)
        let isNew = placeholder?.contentID != content.id
        let wasHidden = placeholder?.isHidden != false
        if isNew {
            placeholder?.removeFromSuperview()
            let button = RequestLogContentButton(content: content, lineID: lineID, owner: owner,
                                                 selected: true, isPlaceholder: true)
            button.alphaValue = 0.3
            placeholder = button
            contentDocument.addSubview(button)
        }
        placeholderSize = size
        placeholderPosition = position
        guard isNew || wasHidden || previousSlot != effectiveSlot(position) else { return }
        placeholder?.isHidden = false
        if previousHeight != intrinsicContentSize.height {
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
        layoutContentControls(animated: true, animatePlaceholder: !wasHidden)
        if isNew || wasHidden, let placeholder { fadeIn(placeholder) }
    }

    func clearDropPreview(animated: Bool = true) {
        guard placeholderPosition != nil else { return }
        let previousHeight = intrinsicContentSize.height
        placeholderPosition = nil
        placeholder?.isHidden = true
        stopOwnedAnimations(on: placeholder)
        if !animated { contentControls.forEach { stopOwnedAnimations(on: $0) } }
        if previousHeight != intrinsicContentSize.height {
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
        layoutContentControls(animated: animated)
    }

    func finishDragFeedback() {
        draggingContentID = nil
        placeholderPosition = nil
        placeholder?.isHidden = true
        stopOwnedAnimations(on: placeholder)
        for control in contentControls {
            control.isHidden = false
            control.alphaValue = 1
            stopOwnedAnimations(on: control)
        }
        invalidateIntrinsicContentSize()
        layoutContentControls(animated: false)
    }

    func autoscrollContents(at point: NSPoint) {
        let local = contentScroll.convert(point, from: self)
        let clip = contentScroll.contentView
        let maximum = max(0, contentDocument.bounds.width - clip.bounds.width)
        guard maximum > 0, contentScroll.bounds.contains(local) else { return }
        let edge: CGFloat = min(24, clip.bounds.width / 4)
        let step: CGFloat = local.x < edge ? -8 : local.x > clip.bounds.width - edge ? 8 : 0
        guard step != 0 else { return }
        let next = min(max(clip.bounds.minX + step, 0), maximum)
        guard next != clip.bounds.minX else { return }
        clip.scroll(to: NSPoint(x: next, y: clip.bounds.minY))
        contentScroll.reflectScrolledClipView(clip)
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        lineGrip.frame = NSRect(x: 6, y: (height - 18) / 2, width: 12, height: 18)
        lineLabel.frame = NSRect(x: 22, y: (height - 18) / 2, width: 52, height: 18)
        let actionsSize = actionsButton.intrinsicContentSize
        let addSize = addButton.intrinsicContentSize
        let actionsX = max(0, bounds.width - 4 - actionsSize.width)
        let addX = max(0, actionsX - 4 - addSize.width)
        actionsButton.frame = NSRect(x: actionsX, y: (height - actionsSize.height) / 2,
                                     width: actionsSize.width, height: actionsSize.height)
        addButton.frame = NSRect(x: addX, y: (height - addSize.height) / 2,
                                 width: addSize.width, height: addSize.height)
        let scrollHeight = contentScrollHeight
        contentScroll.frame = NSRect(x: 78, y: (height - scrollHeight) / 2,
                                     width: max(0, addX - 82), height: scrollHeight)
        contentScroll.layoutSubtreeIfNeeded()
        let documentHeight = max(contentHeight, contentScroll.contentSize.height)
        if contentDocument.frame.height != documentHeight {
            contentDocument.setFrameSize(NSSize(width: contentDocument.frame.width, height: documentHeight))
        }
        layoutContentControls(animated: false)
    }

    private func effectiveSlot(_ position: Int) -> Int {
        if let source = contentControls.firstIndex(where: { $0.contentID == draggingContentID }), position > source {
            return position - 1
        }
        return position
    }

    private func layoutContentControls(animated: Bool, animatePlaceholder: Bool = true) {
        let remaining = contentControls.filter { $0.contentID != draggingContentID }
        let slot = placeholderPosition.map { min(max(effectiveSlot($0), 0), remaining.count) }
        let height = max(contentHeight, contentScroll.contentSize.height)
        let reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let animate = animated && window != nil && !reducesMotion
        if reducesMotion {
            contentControls.forEach { stopOwnedAnimations(on: $0) }
            stopOwnedAnimations(on: placeholder)
        }
        var x: CGFloat = 4
        for index in 0...remaining.count {
            if index == slot, let placeholder {
                let size = placeholderSize ?? placeholder.intrinsicContentSize
                let frame = NSRect(x: x, y: (height - size.height) / 2, width: size.width, height: size.height)
                place(placeholder, at: frame, animated: animate && animatePlaceholder)
                x += size.width + 6
            }
            guard remaining.indices.contains(index) else { continue }
            let control = remaining[index]
            let size = control.intrinsicContentSize
            let frame = NSRect(x: x, y: (height - size.height) / 2, width: size.width, height: size.height)
            place(control, at: frame, animated: animate)
            x += size.width + 6
        }
        let width = max(contentScroll.contentSize.width, x)
        contentDocument.setFrameSize(NSSize(width: width, height: height))
        let clip = contentScroll.contentView
        let maximum = max(0, width - clip.bounds.width)
        if clip.bounds.minX > maximum {
            clip.scroll(to: NSPoint(x: maximum, y: clip.bounds.minY))
            contentScroll.reflectScrolledClipView(clip)
        }
    }

    private func place(_ button: NSButton, at frame: NSRect, animated: Bool) {
        // A normal layout pass must not cancel an animation already heading to
        // this same model frame. Cleanup is explicit at the end of a drag.
        guard button.frame != frame else { return }
        let layer = button.layer
        let from = layer?.presentation()?.position ?? layer?.position
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        button.frame = frame
        CATransaction.commit()
        layer?.removeAnimation(forKey: Self.positionAnimationKey)
        guard animated, let layer, let from, from != layer.position else { return }
        let animation = CABasicAnimation(keyPath: "position")
        animation.fromValue = NSValue(point: from)
        animation.toValue = NSValue(point: layer.position)
        animation.duration = 0.12
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: Self.positionAnimationKey)
    }

    private func fadeIn(_ button: NSButton) {
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = button.layer else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0
        animation.toValue = layer.opacity
        animation.duration = 0.12
        layer.add(animation, forKey: Self.opacityAnimationKey)
    }

    private func stopOwnedAnimations(on button: NSButton?) {
        button?.layer?.removeAnimation(forKey: Self.positionAnimationKey)
        button?.layer?.removeAnimation(forKey: Self.opacityAnimationKey)
    }

    private func configureIcon(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        if #available(macOS 26.0, *) {
            button.bezelStyle = .glass
            button.borderShape = .circle
        } else {
            button.bezelStyle = .circular
        }
        button.target = self; button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }
    @objc private func addPressed(_ sender: NSButton) { addContent(sender) }
    @objc private func actionsPressed(_ sender: NSButton) { showActions(sender) }
}

/// The decorative row grip leaves event tracking to NSTableView's native row drag.
@MainActor
private final class RequestLogLineGripView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class RequestLogContentButton: NSButton, NSDraggingSource {
    let contentID: UUID
    private let payload: RequestLogLayoutDrag
    private let isPlaceholder: Bool
    private var isContentSelected: Bool
    var onSelect: (UUID) -> Void = { _ in }
    var onActions: (UUID, NSButton) -> Void = { _, _ in }
    var onDragBegin: (UUID, NSSize, CGFloat) -> Void = { _, _, _ in }
    var onDragEnd: () -> Void = { }
    private var dragGrabOffsetX: CGFloat = 0

    init(content: RequestLogLayoutContent, lineID: UUID, owner: String, selected: Bool, isPlaceholder: Bool = false) {
        contentID = content.id
        payload = .init(owner: owner, lineID: lineID, contentID: content.id)
        self.isPlaceholder = isPlaceholder
        isContentSelected = selected
        super.init(frame: .zero)
        wantsLayer = true
        focusRingType = .none
        cell?.focusRingType = .none
        title = content.displayTitle.isEmpty ? content.field.title : content.displayTitle
        setButtonType(.momentaryPushIn)
        if #available(macOS 26.0, *) {
            bezelStyle = .glass
            borderShape = .capsule
        } else {
            bezelStyle = .rounded
        }
        cell?.lineBreakMode = .byTruncatingTail
        state = .off
        updateSelectionAppearance()
        toolTip = title + (content.field.stages.isEmpty ? "" : " · " + content.stage.title)
        setAccessibilityLabel(title)
        setAccessibilityHelp("拖动调整位置；右键打开内容操作")
        target = self; action = #selector(pressed)
        if isPlaceholder {
            target = nil; action = nil
            setAccessibilityElement(false)
            setAccessibilityHidden(true)
        }
    }
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { !isPlaceholder && super.acceptsFirstResponder }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isPlaceholder, !isHidden, !isHiddenOrHasHiddenAncestor,
              bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }

    @objc private func pressed() {
        isContentSelected = true
        updateSelectionAppearance()
        onSelect(contentID)
    }

    private func updateSelectionAppearance() {
        applySelectionPresentation(isContentSelected)
        setAccessibilitySelected(isContentSelected)
    }

    private func applySelectionPresentation(_ selected: Bool) {
        bezelColor = selected ? .systemBlue : nil
        if #available(macOS 26.0, *) { tintProminence = selected ? .primary : .automatic }
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: selected ? NSColor.white : NSColor.labelColor]
        if let font { attributes[.font] = font }
        let label = NSAttributedString(string: title, attributes: attributes)
        attributedTitle = label
        attributedAlternateTitle = label
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onActions(contentID, self)
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }
        if event.modifierFlags.contains(.control) {
            onActions(contentID, self)
            return
        }
        let startPoint = event.locationInWindow
        var crossedDragThreshold = false
        var shouldSelect = false
        highlight(true)
        // NSButton's own mouseDown consumes dragged events while tracking the click.
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .greatestFiniteMagnitude,
                           mode: .eventTracking) { trackingEvent, stop in
            guard let trackingEvent else {
                stop.pointee = true
                return
            }
            let point = convert(trackingEvent.locationInWindow, from: nil)
            if trackingEvent.type == .leftMouseUp {
                shouldSelect = bounds.contains(point)
                stop.pointee = true
            } else if hypot(trackingEvent.locationInWindow.x - startPoint.x,
                            trackingEvent.locationInWindow.y - startPoint.y) >= 4 {
                crossedDragThreshold = true
                stop.pointee = true
            } else {
                highlight(bounds.contains(point))
            }
        }
        highlight(false)
        if crossedDragThreshold {
            beginContentDrag(with: event)
        } else if shouldSelect {
            if acceptsFirstResponder { window.makeFirstResponder(self) }
            performClick(nil)
        }
    }

    private func beginContentDrag(with event: NSEvent) {
        guard let host = window?.contentView,
              let pasteboardItem = payload.pasteboardItem(for: .requestLogContent),
              let image = contentDraggingImage() else { return }
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
        // The initiating view's visible area clips AppKit's drag image. Keep
        // this host outside the scrolling document that reflows during a drag.
        dragGrabOffsetX = min(max(convert(event.locationInWindow, from: nil).x - bounds.minX, 0), bounds.width)
        let frame = host.convert(bounds, from: self)
        item.setDraggingFrame(frame, contents: image)
        let session = host.beginDraggingSession(with: [item], event: event, source: self)
        session.draggingFormation = .none
        session.animatesToStartingPositionsOnCancelOrFail = true
        alphaValue = 0.45
    }

    private func contentDraggingImage() -> NSImage? {
        // Render the drag image synchronously with a native button cell. Its
        // pixels are independent of the source control's composited layers.
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = window?.backingScaleFactor ?? 1
        guard let representation = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(size.width * scale)), pixelsHigh: Int(ceil(size.height * scale)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        // AppKit derives the point-to-pixel scale from this logical size.
        representation.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: representation) else { return nil }
        let renderer = NSButton(frame: NSRect(origin: .zero, size: size))
        renderer.appearance = effectiveAppearance
        let dragFont = font ?? .systemFont(ofSize: NSFont.systemFontSize)
        renderer.setButtonType(.momentaryPushIn)
        renderer.bezelStyle = .push
        if #available(macOS 26.0, *) { renderer.borderShape = .capsule }
        renderer.controlSize = controlSize
        renderer.focusRingType = .none
        renderer.font = dragFont
        renderer.state = .off
        renderer.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: dragFont, .foregroundColor: NSColor.labelColor
        ])
        guard let nativeCell = renderer.cell as? NSButtonCell else { return nil }
        nativeCell.isBordered = true
        nativeCell.focusRingType = .none
        nativeCell.isHighlighted = false
        nativeCell.showsFirstResponder = false
        nativeCell.lineBreakMode = .byTruncatingTail
        NSGraphicsContext.saveGraphicsState()
        let graphics = context.cgContext
        graphics.clear(NSRect(origin: .zero, size: size))
        if renderer.isFlipped {
            graphics.translateBy(x: 0, y: size.height)
            graphics.scaleBy(x: 1, y: -1)
        }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: graphics, flipped: renderer.isFlipped)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            nativeCell.draw(withFrame: renderer.bounds, in: renderer)
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(representation)
        return image
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        onDragBegin(contentID, bounds.size, dragGrabOffsetX)
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        alphaValue = 1
        onDragEnd()
    }
}

@MainActor
final class RequestLogFormScrollView: NSScrollView {
    private let form: NSStackView
    private let document = FlippedView()
    private var sizingDocument = false

    init(content: NSStackView) {
        form = content
        super.init(frame: .zero)
        borderType = .noBorder
        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        horizontalScrollElasticity = .none
        documentView = document
        form.translatesAutoresizingMaskIntoConstraints = false
        form.setContentHuggingPriority(.required, for: .vertical)
        form.setContentCompressionResistancePriority(.required, for: .vertical)
        document.addSubview(form)
        NSLayoutConstraint.activate([
            form.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            form.topAnchor.constraint(equalTo: document.topAnchor)
        ])
        form.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(formFrameChanged),
                                               name: NSView.frameDidChangeNotification, object: form)
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        sizeDocument()
    }
    @objc private func formFrameChanged() { sizeDocument() }

    private func sizeDocument() {
        guard !sizingDocument else { return }
        sizingDocument = true
        defer { sizingDocument = false }
        let width = contentView.bounds.width
        guard width > 0 else { return }
        document.setFrameSize(NSSize(width: width, height: document.frame.height))
        document.layoutSubtreeIfNeeded()
        let height = max(contentView.bounds.height, ceil(form.fittingSize.height))
        if abs(document.frame.height - height) > 0.1 {
            document.setFrameSize(NSSize(width: width, height: height))
        }
    }
}
