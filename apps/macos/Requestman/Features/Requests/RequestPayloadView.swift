import AppKit
import SwiftUI
import RequestmanCore

struct RequestPayloadView: View {
    let record: CaptureRecord
    let tab: RequestDetailTab
    let isActive: Bool
    @State private var version: InspectionVersion = .final
    @State private var format: InspectionFormat = .tree
    @State private var search = ""
    @State private var onlyChanges = false
    @State private var presentation: RequestPayloadPresentation?
    @State private var isLoading = true

    private var visibleNodes: [RequestDataNode] {
        RequestInspectionData.filtering(presentation?.nodes ?? [], query: search, onlyChanges: onlyChanges)
    }

    private var searchPrompt: String {
        guard tab.isBody else { return "查找\(tab.title)" }
        return presentation?.isJSON == true && format == .tree ? "查找键或值" : "查找原始数据"
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar.padding(.horizontal, 16).padding(.bottom, 10)
            if let presentation {
                HStack(spacing: 8) {
                    Text(direction).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(presentation.summary).lineLimit(1).help(presentation.footer)
                    if presentation.canCompare && (!tab.isBody || (presentation.isJSON && format == .tree)) {
                        Toggle("仅显示变更", isOn: $onlyChanges)
                            .toggleStyle(.checkbox).controlSize(.small).fixedSize()
                            .disabled(isLoading)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.bottom, 10)
                if let notice = presentation.notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.bottom, 8)
                }
                Divider()
                content(presentation)
                    .opacity(isLoading ? 0 : 1)
                    .allowsHitTesting(!isLoading && isActive)
                    .overlay { if isLoading { ProgressView().controlSize(.small) } }
            } else {
                Spacer()
                ProgressView("正在读取内容").controlSize(.small)
                Spacer()
            }
        }
        .task(id: version) {
            isLoading = true
            let snapshot = record
            let selectedTab = tab
            let selectedVersion = version
            let worker = Task.detached(priority: .userInitiated) {
                RequestPayloadPresentation.make(record: snapshot, tab: selectedTab, version: selectedVersion)
            }
            let next = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            presentation = next
            isLoading = false
            if !next.canCompare { onlyChanges = false }
        }
        .onChange(of: format) { _, _ in NSApp.keyWindow?.makeFirstResponder(nil) }
        .onChange(of: version) { _, _ in NSApp.keyWindow?.makeFirstResponder(nil) }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("数据版本", selection: $version) {
                ForEach(InspectionVersion.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu).labelsHidden().fixedSize()
            .help("原始内容、最终内容或两者的差异")
            if tab.isBody, presentation?.isJSON == true {
                Button(format == .tree ? "原始数据" : "树形视图") {
                    format = format == .tree ? .source : .tree
                }
                .buttonStyle(.bordered).fixedSize()
                .disabled(isLoading)
                .help(format == .tree ? "查看当前版本的原始数据" : "以字段树查看当前版本的 JSON")
            }
            TextField(searchPrompt, text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(searchPrompt)
            Button {
                if let presentation { RequestClipboard.copy(presentation.copyText) }
            } label: { Label("复制当前\(tab.title)", systemImage: "doc.on.doc") }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .disabled(isLoading || presentation?.copyText.isEmpty != false)
                .help("复制当前\(tab.title)")
        }.controlSize(.small).padding(.top, 10)
    }

    private func content(_ data: RequestPayloadPresentation) -> some View {
        let usesSource = tab.isBody && (!data.isJSON || format == .source)
        let showsContent = isActive && !isLoading && data.emptyTitle == nil
        let nodes = visibleNodes
        return ZStack {
            // Keep both native views alive across format/search/version changes.
            RequestDataOutline(nodes: nodes, showsTypes: tab.isBody,
                               isVisible: showsContent && !usesSource,
                               stateKey: "\(version.rawValue)-\(search.isEmpty ? "all" : "search")-\(onlyChanges)",
                               expandsMatches: !search.isEmpty || onlyChanges)
                .opacity(!usesSource && data.emptyTitle == nil ? 1 : 0)
                .allowsHitTesting(!usesSource && data.emptyTitle == nil)
                .accessibilityHidden(usesSource || data.emptyTitle != nil)
            if tab.isBody {
                RequestSourceView(text: data.source, search: usesSource ? search : "", stateKey: version.rawValue,
                                  isVisible: showsContent && usesSource)
                    .opacity(usesSource && data.emptyTitle == nil ? 1 : 0)
                    .allowsHitTesting(usesSource && data.emptyTitle == nil)
                    .accessibilityHidden(!usesSource || data.emptyTitle != nil)
            }
            if let title = data.emptyTitle {
                ContentUnavailableView(title, systemImage: "doc.text", description: Text(data.emptyDescription ?? ""))
            } else if !usesSource && nodes.isEmpty {
                ContentUnavailableView(onlyChanges ? "没有符合条件的变更" : "没有匹配字段", systemImage: "magnifyingglass",
                                       description: Text("调整搜索或筛选条件。"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var direction: String {
        if version == .difference { return tab.isRequest ? "客户端原始 → 发往服务器" : "服务器原始 → 发往客户端" }
        if tab.isRequest { return version == .original ? "客户端原始请求" : "发往服务器" }
        let status = version == .original ? record.originalStatus : record.status
        let title = version == .original ? "服务器原始响应" : "发往客户端"
        return status.map { "\(title) · \($0)" } ?? title
    }
}

/// Read-only native text selection, find highlighting and copying for non-JSON bodies and source mode.
private struct RequestSourceView: NSViewRepresentable {
    let text: String
    let search: String
    let stateKey: String
    let isVisible: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.isHidden = !isVisible
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
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        view.setAccessibilityLabel("Body 源码")
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
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
        let coordinator = context.coordinator
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
        var stateKey = ""
        var positions: [String: NSPoint] = [:]
    }
}
