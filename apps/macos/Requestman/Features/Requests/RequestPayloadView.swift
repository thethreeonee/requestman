import AppKit
import RequestmanCore

@MainActor
final class RequestPayloadViewController: NSViewController, NSSearchFieldDelegate {
    private var record: CaptureRecord
    let tab: RequestDetailTab
    var onCopyChange: () -> Void = {}
    private var format: InspectionFormat = .tree
    private var search = ""
    private var onlyChanges = false
    private var showsImageSource = false
    private var presentation: RequestPayloadPresentation?
    private var version: InspectionVersion
    private var presentedVersion: InspectionVersion?
    private var active = false
    private var isLoading = true
    private var task: Task<Void, Never>?
    private var generation = 0
    private let directionLabel = NativeUI.label("", size: 11, secondary: true)
    private let summary = NativeUI.label("", size: 11, secondary: true)
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let changes = NSButton(checkboxWithTitle: "仅显示变更", target: nil, action: nil)
    private let outline = RequestDataOutline()
    private let source = RequestSourceView()
    private let imageView = NSImageView()
    private let imageComparison = RequestImageComparisonView()
    private let imageSource = NSButton(checkboxWithTitle: "显示原始数据", target: nil, action: nil)
    private var imageOptions: NSStackView!
    private let empty = RequestEmptyStateView()
    private let progress = NSProgressIndicator()
    private let formatButton = NSButton(title: "原始数据", target: nil, action: nil)
    private let searchField = NSSearchField()
    private let dataContainer = NSView()
    private var header: NSStackView!

    init(record: CaptureRecord, tab: RequestDetailTab, version: InspectionVersion) {
        self.record = record; self.tab = tab; self.version = version
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    deinit { task?.cancel() }
    override func loadView() {
        view = FlippedView()
        changes.controlSize = .small; changes.target = self; changes.action = #selector(toggleChanges)
        directionLabel.lineBreakMode = .byTruncatingTail; summary.lineBreakMode = .byTruncatingTail
        summary.setContentHuggingPriority(.required, for: .horizontal)
        changes.setContentHuggingPriority(.required, for: .horizontal)
        notice.font = .systemFont(ofSize: 11); notice.textColor = .secondaryLabelColor
        let info = NativeUI.stack([directionLabel, NSView(), summary, changes], vertical: false, spacing: 8)
        info.distribution = .fill
        imageSource.controlSize = .small
        imageSource.target = self; imageSource.action = #selector(toggleImageSource)
        imageSource.setContentHuggingPriority(.required, for: .horizontal)
        imageOptions = NativeUI.stack([NSView(), imageSource], vertical: false, spacing: 0)
        imageOptions.distribution = .fill
        imageOptions.heightAnchor.constraint(equalToConstant: imageSource.intrinsicContentSize.height).isActive = true
        header = NativeUI.stack([info, imageOptions, notice], spacing: 8)
        header.alignment = .leading
        info.widthAnchor.constraint(equalTo: header.widthAnchor, constant: -32).isActive = true
        imageOptions.widthAnchor.constraint(equalTo: info.widthAnchor).isActive = true
        notice.widthAnchor.constraint(equalTo: header.widthAnchor, constant: -32).isActive = true
        header.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 10, right: 16)
        let separator = NSBox(); separator.boxType = .separator
        progress.style = .spinning; progress.controlSize = .small
        for child in [outline, source] { NativeUI.pin(child, to: dataContainer) }
        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        imageView.setAccessibilityLabel("响应图片预览")
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imageView.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        NativeUI.pin(imageView, to: dataContainer, insets: NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16))
        NativeUI.pin(imageComparison, to: dataContainer)
        for child in [empty, progress] {
            child.translatesAutoresizingMaskIntoConstraints = false; dataContainer.addSubview(child)
            child.centerXAnchor.constraint(equalTo: dataContainer.centerXAnchor).isActive = true
            child.centerYAnchor.constraint(equalTo: dataContainer.centerYAnchor).isActive = true
        }
        empty.widthAnchor.constraint(lessThanOrEqualTo: dataContainer.widthAnchor, constant: -32).isActive = true
        formatButton.target = self; formatButton.action = #selector(toggleFormat)
        searchField.delegate = self; searchField.sendsSearchStringImmediately = true
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for control in [formatButton, searchField] as [NSControl] { control.controlSize = .large }
        if #available(macOS 26.0, *) { formatButton.bezelStyle = .glass; formatButton.borderShape = .capsule }
        else { formatButton.bezelStyle = .rounded }
        formatButton.setContentHuggingPriority(.required, for: .horizontal)
        let controls = NativeUI.stack([formatButton, searchField], vertical: false, spacing: 10)
        controls.distribution = .fill
        controls.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        let stack = NativeUI.stack([header, separator, dataContainer, controls], spacing: 0)
        NativeUI.pin(stack, to: view)
        for child in [header!, separator, dataContainer, controls] { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        dataContainer.setContentHuggingPriority(.defaultLow, for: .vertical)
        dataContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
        searchField.heightAnchor.constraint(equalToConstant: searchField.intrinsicContentSize.height).isActive = true
        formatButton.heightAnchor.constraint(equalTo: searchField.heightAnchor).isActive = true
        loadPresentation()
    }
    func update(record next: CaptureRecord, version: InspectionVersion, isActive: Bool) {
        let changed = record.status != next.status || record.requestHeaders != next.requestHeaders
            || record.sentHeaders != next.sentHeaders || record.receivedHeaders != next.receivedHeaders
            || record.responseHeaders != next.responseHeaders || record.finalURL != next.finalURL
            || record.requestBody.state != next.requestBody.state || record.sentBody.state != next.sentBody.state
            || record.receivedBody.state != next.receivedBody.state || record.responseBody.state != next.responseBody.state
        record = next
        if changed, isViewLoaded { self.version = version; active = isActive; loadPresentation() }
        else { update(version: version, isActive: isActive) }
    }
    func update(version: InspectionVersion, isActive: Bool) {
        let changed = self.version != version
        self.version = version; active = isActive
        guard isViewLoaded else { return }
        if changed {
            if active, !(view.window?.firstResponder is NSSegmentedControl) { view.window?.makeFirstResponder(nil) }
            loadPresentation()
        } else { refreshContent() }
    }
    var copyContent: RequestPayloadCopyContent? {
        guard active, !isLoading, let presentation, let presentedVersion else { return nil }
        return .init(tab: tab, version: presentedVersion, text: presentation.copyText)
    }
    private func loadPresentation() {
        task?.cancel(); generation += 1
        let generation = generation, snapshot = record, tab = tab, version = version
        isLoading = true; refreshContent()
        task = Task { @MainActor [weak self] in
            let worker = Task.detached(priority: .userInitiated) { RequestPayloadPresentation.make(record: snapshot, tab: tab, version: version) }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            self.presentation = result; self.presentedVersion = version; self.isLoading = false
            let image = result.imageData.flatMap { NSImage(data: $0) }
            self.imageView.image = image?.isValid == true ? image : nil
            self.imageComparison.update(result.imageComparison)
            if !result.canCompare { self.onlyChanges = false }
            self.refreshContent()
        }
    }
    private func refreshContent() {
        guard isViewLoaded else { return }
        directionLabel.stringValue = direction
        summary.stringValue = presentation?.summary ?? ""
        summary.toolTip = presentation?.footer
        let comparesImages = presentation?.imageComparison.count == 2
        let isImageResponse = presentation?.imageData != nil || comparesImages
        let hasImage = imageView.image != nil || comparesImages
        let usesImage = hasImage && !showsImageSource
        var noticeText = usesImage ? presentation?.imageNotice : presentation?.notice
        if isImageResponse && !hasImage {
            noticeText = ["无法预览此图片，当前显示原始数据。", noticeText].compactMap { $0 }.joined(separator: " ")
        }
        notice.stringValue = noticeText ?? ""; notice.isHidden = noticeText?.isEmpty != false
        imageOptions.isHidden = !hasImage || isLoading
        imageSource.state = showsImageSource ? .on : .off
        imageSource.isEnabled = active && !isLoading
        changes.isHidden = isImageResponse || !(presentation?.canCompare == true && (!tab.isBody || (presentation?.isJSON == true && format == .tree)))
        changes.state = onlyChanges ? .on : .off; changes.isEnabled = !isLoading && active
        let usesSource = !usesImage && tab.isBody && (isImageResponse || presentation?.isJSON != true || format == .source)
        let nodes = RequestInspectionData.filtering(presentation?.nodes ?? [], query: search, onlyChanges: onlyChanges)
        let showsContent = active && !isLoading && presentation?.emptyTitle == nil
        imageView.isHidden = !showsContent || !usesImage || comparesImages
        imageView.animates = !imageView.isHidden
        imageComparison.setVisible(showsContent && usesImage && comparesImages)
        outline.update(nodes: nodes, showsTypes: tab.isBody, isVisible: showsContent && !usesSource && !usesImage,
                       stateKey: "\(version.rawValue)-\(search.isEmpty ? "all" : "search")-\(onlyChanges)", expandsMatches: !search.isEmpty || onlyChanges)
        outline.isHidden = usesSource || usesImage || !showsContent
        source.update(text: presentation?.source ?? "", search: usesSource ? search : "", stateKey: version.rawValue,
                      isVisible: showsContent && usesSource, isJSON: presentation?.isJSON == true)
        source.isHidden = !usesSource || isLoading || presentation?.emptyTitle != nil
        let title = presentation?.emptyTitle ?? ((!usesSource && !usesImage && nodes.isEmpty) ? (onlyChanges ? "没有符合条件的变更" : "没有匹配字段") : "")
        empty.update(title: title, description: presentation?.emptyDescription ?? "调整搜索或筛选条件。", symbol: presentation?.emptyTitle == nil ? "magnifyingglass" : "doc.text")
        empty.isHidden = title.isEmpty || isLoading
        progress.isHidden = !isLoading
        if isLoading { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        formatButton.isHidden = isImageResponse || !(tab.isBody && presentation?.isJSON == true)
        formatButton.title = format == .tree ? "原始数据" : "树形视图"
        formatButton.toolTip = format == .tree ? "查看当前版本的原始数据" : "以字段树查看当前版本的 JSON"
        formatButton.isEnabled = active && !isLoading
        if searchField.stringValue != search { searchField.stringValue = search }
        let prompt = !tab.isBody ? "查找\(tab.title)" : (!usesSource && presentation?.isJSON == true && format == .tree ? "查找键或值" : "查找原始数据")
        searchField.placeholderString = prompt; searchField.setAccessibilityLabel(prompt); searchField.isEnabled = active && !usesImage
        if !active, let editor = searchField.currentEditor(), editor === view.window?.firstResponder { view.window?.makeFirstResponder(nil) }
        onCopyChange()
    }
    @objc private func toggleChanges() { onlyChanges = changes.state == .on; refreshContent() }
    @objc private func toggleImageSource() {
        showsImageSource = imageSource.state == .on
        view.window?.makeFirstResponder(nil); refreshContent()
    }
    @objc private func toggleFormat() {
        format = format == .tree ? .source : .tree
        view.window?.makeFirstResponder(nil); refreshContent()
    }
    func controlTextDidChange(_ notification: Notification) { search = searchField.stringValue; refreshContent() }
    private var direction: String {
        if tab == .queryParameters {
            switch version {
            case .original: return "原始 URL"
            case .final: return "最终 URL"
            case .difference: return "原始 URL → 最终 URL"
            }
        }
        if version == .difference { return tab.isRequest ? "客户端原始 → 发往服务器" : "服务器原始 → 发往客户端" }
        if tab.isRequest { return version == .original ? "客户端原始请求" : "发往服务器" }
        let status = version == .original ? record.originalStatus : record.status
        let title = version == .original ? "服务器原始响应" : "发往客户端"
        return status.map { "\(title) · \($0)" } ?? title
    }
}

struct RequestPayloadCopyContent: Equatable, Sendable {
    let tab: RequestDetailTab
    let version: InspectionVersion
    let text: String
}

/// Equal-width before/after columns; all content uses native AppKit views.
@MainActor
private final class RequestImageComparisonView: NSView {
    private let columns = [Column(), Column()]

    override init(frame: NSRect) {
        super.init(frame: frame)
        let stack = NativeUI.stack(columns, vertical: false, spacing: 16)
        stack.distribution = .fillEqually
        stack.alignment = .top
        NativeUI.pin(stack, to: self, insets: NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16))
        for column in columns { column.heightAnchor.constraint(equalTo: stack.heightAnchor).isActive = true }
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }

    func update(_ previews: [RequestPayloadPresentation.ImagePreview]) {
        for (index, column) in columns.enumerated() {
            column.update(previews.indices.contains(index) ? previews[index] : nil)
        }
    }

    func setVisible(_ visible: Bool) {
        isHidden = !visible
        for column in columns { column.image.animates = visible && column.image.image != nil }
    }

    private final class Column: NSView {
        let image = NSImageView()
        private let title = NativeUI.label("", size: 12, weight: .semibold)
        private let message = NSTextField(wrappingLabelWithString: "")

        override init(frame: NSRect) {
            super.init(frame: frame)
            title.alignment = .center
            title.translatesAutoresizingMaskIntoConstraints = false
            addSubview(title)
            let content = NSView()
            content.translatesAutoresizingMaskIntoConstraints = false
            addSubview(content)
            NSLayoutConstraint.activate([
                title.topAnchor.constraint(equalTo: topAnchor),
                title.leadingAnchor.constraint(equalTo: leadingAnchor),
                title.trailingAnchor.constraint(equalTo: trailingAnchor),
                title.heightAnchor.constraint(equalToConstant: title.intrinsicContentSize.height),
                content.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
                content.leadingAnchor.constraint(equalTo: leadingAnchor),
                content.trailingAnchor.constraint(equalTo: trailingAnchor),
                content.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            image.imageScaling = .scaleProportionallyDown
            image.imageAlignment = .alignCenter
            for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
                image.setContentCompressionResistancePriority(.defaultLow, for: orientation)
                image.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: orientation)
            }
            NativeUI.pin(image, to: content)
            message.font = .systemFont(ofSize: 11)
            message.textColor = .secondaryLabelColor
            message.alignment = .center
            message.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(message)
            NSLayoutConstraint.activate([
                message.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                message.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                message.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ])
        }
        convenience init() { self.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }

        func update(_ preview: RequestPayloadPresentation.ImagePreview?) {
            title.stringValue = preview?.title ?? ""
            let decoded = preview?.data.flatMap { NSImage(data: $0) }
            image.image = decoded?.isValid == true ? decoded : nil
            image.setAccessibilityLabel("\(preview?.title ?? "")图片预览")
            image.isHidden = image.image == nil
            message.stringValue = preview?.unavailableReason ?? "无法预览此图片，可勾选“显示原始数据”查看内容。"
            message.isHidden = image.image != nil
        }
    }
}

@MainActor
final class RequestSourceView: NSView {
    private let scroll = NSScrollView()
    private let coordinator = Coordinator()
    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.usesFindBar = true
        view.isAutomaticLinkDetectionEnabled = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textColor = .labelColor
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 6, height: 4)
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        view.setAccessibilityLabel("Body 源码")
        scroll.documentView = view
        scroll.frame = bounds
        scroll.autoresizingMask = [.width, .height]
        addSubview(scroll)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }

    func setFont(_ font: NSFont) { (scroll.documentView as? NSTextView)?.font = font }

    func update(text: String, search: String, stateKey: String, isVisible: Bool, isJSON: Bool = false) {
        guard let view = scroll.documentView as? NSTextView else { return }
        // Keep the view alive for scroll state, but hide it natively as well
        // so its I-beam cursor regions cannot cover the visible field table.
        if scroll.isHidden == isVisible {
            if !isVisible, view.window?.firstResponder === view {
                view.window?.makeFirstResponder(nil)
            }
            scroll.isHidden = !isVisible
            view.window?.invalidateCursorRects(for: view)
        }
        let changed = coordinator.text != text || coordinator.stateKey != stateKey
        if changed {
            coordinator.positions[coordinator.stateKey] = scroll.contentView.bounds.origin
            coordinator.text = text
            coordinator.stateKey = stateKey
            view.string = text
            view.layoutManager?.ensureLayout(for: view.textContainer!)
            scroll.contentView.scroll(to: coordinator.positions[stateKey] ?? .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        if changed || coordinator.isJSON != isJSON {
            coordinator.isJSON = isJSON
            coordinator.needsSyntaxUpdate = true
        }
        if isVisible && coordinator.needsSyntaxUpdate {
            JSONSyntax.highlight(view, enabled: isJSON)
            coordinator.needsSyntaxUpdate = false
        }
        if changed || coordinator.search != search {
            coordinator.search = search
            let whole = NSRange(location: 0, length: (text as NSString).length)
            view.textStorage?.removeAttribute(.backgroundColor, range: whole)
            guard !search.isEmpty else { return }
            var remaining = whole
            var first: NSRange?
            while remaining.length > 0 {
                let range = (text as NSString).range(of: search, options: [.caseInsensitive], range: remaining)
                guard range.location != NSNotFound else { break }
                if first == nil { first = range }
                view.textStorage?.addAttribute(.backgroundColor, value: NSColor.findHighlightColor.withAlphaComponent(0.35), range: range)
                remaining = NSRange(location: NSMaxRange(range), length: whole.length - NSMaxRange(range))
            }
            if let first { view.scrollRangeToVisible(first) }
        }
    }

    @MainActor final class Coordinator {
        var text = ""
        var search = ""
        var isJSON = false
        var needsSyntaxUpdate = true
        var stateKey = ""
        var positions: [String: NSPoint] = [:]
    }
}

/// Business empty-state content built from native labels and an image view.
@MainActor
final class RequestEmptyStateView: NSView {
    private let icon = NSImageView()
    private var symbolName = ""
    private let title = NativeUI.label("", size: 20, weight: .semibold)
    private let detail = NSTextField(wrappingLabelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.contentTintColor = .tertiaryLabelColor
        icon.symbolConfiguration = .init(pointSize: 40, weight: .regular)
        title.alignment = .center; detail.alignment = .center
        detail.font = .systemFont(ofSize: 13); detail.textColor = .secondaryLabelColor
        let stack = NativeUI.stack([icon, title, detail], spacing: 10)
        stack.alignment = .centerX
        NativeUI.pin(stack, to: self)
        detail.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        title.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 46).isActive = true
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: 320, height: 130) }
    func update(title: String, description: String, symbol: String) {
        self.title.stringValue = title; detail.stringValue = description
        if symbolName != symbol { icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); symbolName = symbol }
    }
}
