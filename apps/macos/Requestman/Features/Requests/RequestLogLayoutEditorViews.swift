import AppKit
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
    var dragEnded: () -> Void = { }

    private let lineGrip = RequestLogLineGripView()
    private let lineLabel = NSTextField(labelWithString: "")
    private let contentScroll = NSScrollView()
    private let contentDocument = FlippedView()
    private let insertionIndicator = NSBox()
    private var insertionIndex: Int?
    private var contentControls: [RequestLogContentButton] = []
    private let addButton = NSButton()
    private let actionsButton = NSButton()

    init(line: RequestLogLayoutLine, index: Int, selectedID: UUID?, owner: String) {
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
        insertionIndicator.boxType = .custom
        insertionIndicator.titlePosition = .noTitle
        insertionIndicator.borderWidth = 0
        insertionIndicator.fillColor = .systemBlue
        insertionIndicator.cornerRadius = 1
        insertionIndicator.isHidden = true
        insertionIndicator.setAccessibilityElement(false)

        configureIcon(addButton, symbol: "plus", label: "添加内容", action: #selector(addPressed(_:)))
        configureIcon(actionsButton, symbol: "ellipsis", label: "行操作", action: #selector(actionsPressed(_:)))
        for view in [lineGrip, lineLabel, contentScroll, addButton, actionsButton] { addSubview(view) }
        for content in line.contents {
            let control = RequestLogContentButton(content: content, lineID: line.id, owner: owner,
                                                  selected: content.id == selectedID)
            control.onSelect = { [weak self] in self?.selectContent($0) }
            control.onActions = { [weak self] in self?.contentActions($0, $1) }
            control.onDragEnd = { [weak self] in self?.dragEnded() }
            contentControls.append(control)
            contentDocument.addSubview(control)
        }
        contentDocument.addSubview(insertionIndicator)
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
            contentControls.map(\.intrinsicContentSize.height).max() ?? 0)
    }

    private var contentScrollHeight: CGFloat {
        let scrollerHeight = contentScroll.scrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: contentScroll.horizontalScroller?.controlSize ?? .regular, scrollerStyle: .legacy) : 0
        return contentHeight + scrollerHeight
    }

    func contentInsertionIndex(at point: NSPoint) -> Int {
        let point = contentDocument.convert(point, from: self)
        for (index, control) in contentControls.enumerated() {
            let buttonBounds = contentDocument.convert(control.bounds, from: control)
            if point.x < buttonBounds.midX { return index }
        }
        return contentControls.count
    }

    func showInsertion(at index: Int?) {
        insertionIndex = index
        insertionIndicator.isHidden = index == nil
        layoutInsertionIndicator()
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
        var x: CGFloat = 4
        for control in contentControls {
            let size = control.intrinsicContentSize
            control.frame = NSRect(x: x, y: (documentHeight - size.height) / 2,
                                   width: size.width, height: size.height)
            x += size.width + 6
        }
        // Reserve space at both ends so the insertion mark remains visible when fully scrolled.
        let documentWidth = max(contentScroll.contentSize.width, x)
        contentDocument.setFrameSize(NSSize(width: documentWidth, height: documentHeight))
        layoutInsertionIndicator()
    }

    private func layoutInsertionIndicator() {
        guard let insertionIndex else { return }
        let x: CGFloat
        if contentControls.indices.contains(insertionIndex) {
            x = max(1, contentControls[insertionIndex].frame.minX - 3)
        } else { x = (contentControls.last?.frame.maxX ?? 0) + 3 }
        insertionIndicator.frame = NSRect(x: x - 1, y: 2, width: 2,
                                          height: max(0, contentDocument.bounds.height - 4))
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
    private let contentID: UUID
    private let payload: RequestLogLayoutDrag
    var onSelect: (UUID) -> Void = { _ in }
    var onActions: (UUID, NSButton) -> Void = { _, _ in }
    var onDragEnd: () -> Void = { }

    init(content: RequestLogLayoutContent, lineID: UUID, owner: String, selected: Bool) {
        contentID = content.id
        payload = .init(owner: owner, lineID: lineID, contentID: content.id)
        super.init(frame: .zero)
        title = content.displayTitle.isEmpty ? content.field.title : content.displayTitle
        setButtonType(.pushOnPushOff)
        if #available(macOS 26.0, *) {
            bezelStyle = .glass
            borderShape = .capsule
        } else {
            bezelStyle = .rounded
        }
        cell?.lineBreakMode = .byTruncatingTail
        state = selected ? .on : .off
        updateSelectionAppearance()
        toolTip = title + (content.field.stages.isEmpty ? "" : " · " + content.stage.title)
        setAccessibilityLabel(title)
        setAccessibilityHelp("拖动调整位置；右键打开内容操作")
        target = self; action = #selector(pressed)
    }
    required init?(coder: NSCoder) { nil }

    @objc private func pressed() {
        state = .on
        updateSelectionAppearance()
        onSelect(contentID)
    }

    private func updateSelectionAppearance() {
        let selected = state == .on
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
        if acceptsFirstResponder { window.makeFirstResponder(self) }
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
            performClick(nil)
        }
    }

    private func beginContentDrag(with event: NSEvent) {
        guard let sourceView = superview,
              let pasteboardItem = payload.pasteboardItem(for: .requestLogContent),
              let representation = bitmapImageRepForCachingDisplay(in: bounds) else { return }
        cacheDisplay(in: bounds, to: representation)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(representation)
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
        // AppKit uses the original mouse-down location to preserve the point being held.
        let frame = sourceView.convert(bounds, from: self)
        item.setDraggingFrame(frame, contents: image)
        let session = sourceView.beginDraggingSession(with: [item], event: event, source: self)
        session.draggingFormation = .none
        session.animatesToStartingPositionsOnCancelOrFail = true
        alphaValue = 0.45
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
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
