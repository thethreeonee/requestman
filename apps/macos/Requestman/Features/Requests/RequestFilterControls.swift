import AppKit
import SwiftUI
import RequestmanCore

struct RequestFilterControls: View {
    @Binding var filter: CaptureRecordFilter
    let records: [CaptureRecord]
    let paused: Bool
    let toggleRecording: () -> Void
    let clear: () -> Void
    @State private var showingFilters = false

    var body: some View {
        HStack(spacing: 10) {
            RequestFilterActionButton(symbol: paused ? "play" : "pause",
                label: paused ? "继续记录" : "暂停记录", help: paused ? "继续记录" : "暂停记录（代理继续工作）",
                action: toggleRecording).fixedSize()
            RequestFilterActionButton(symbol: "trash", label: "清空", help: "清空全部请求日志",
                action: clear).fixedSize().disabled(records.isEmpty)
            Divider().frame(height: 20)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Picker("资源类型", selection: primaryResource) {
                        ForEach(primaryTypes, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                    Menu {
                        ForEach(extraTypes, id: \.self) { type in
                            Button { filter.resource = type } label: {
                                if filter.resource == type { Label(type.rawValue, systemImage: "checkmark") }
                                else { Text(type.rawValue) }
                            }
                        }
                    } label: { Text(extraTypes.contains(filter.resource) ? filter.resource.rawValue : "更多") }
                    .fixedSize()
                }.fixedSize()
                Picker("资源类型", selection: $filter.resource) {
                    ForEach(CaptureResourceType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 86)
            }
            Spacer(minLength: 0)
            Button { showingFilters.toggle() } label: {
                HStack(spacing: 4) {
                    Text(filter.activeConditionCount == 0 ? "筛选" : "筛选 \(filter.activeConditionCount)")
                    Image(systemName: showingFilters ? "chevron.up" : "chevron.down").font(.caption2)
                }
            }
            .fixedSize().help("筛选项目、环境、结果、方法和请求 Header")
            .popover(isPresented: $showingFilters, arrowEdge: .bottom) {
                RequestFilterPanel(filter: $filter, records: records)
            }
        }
        .controlSize(.regular)
        .padding(.horizontal, 12).frame(height: 48)
        .accessibilityElement(children: .contain).accessibilityLabel("请求日志筛选")
    }

    private var primaryTypes: [CaptureResourceType] { [.all, .json, .document, .css, .script, .image] }
    private var extraTypes: [CaptureResourceType] { [.font, .media, .other] }
    // A nil selection leaves the primary segments unselected while an overflow type is active.
    private var primaryResource: Binding<CaptureResourceType?> {
        Binding(get: { primaryTypes.contains(filter.resource) ? filter.resource : nil },
                set: { if let type = $0 { filter.resource = type } })
    }
}

struct RequestFilterPanel: View {
    @Binding var filter: CaptureRecordFilter
    let records: [CaptureRecord]
    private var projects: [String] { Array(Set(records.map(\.project)).union(filter.project.isEmpty ? [] : [filter.project])).sorted() }
    private var environments: [String] { Array(Set(records.map(\.environment)).union(filter.environment.isEmpty ? [] : [filter.environment])).sorted() }
    private var methods: [String] {
        Array(Set(records.map(\.method)).union(["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"])
            .union(filter.method.isEmpty ? [] : [filter.method])).sorted()
    }
    private var headerNames: [String] {
        let captured = records.flatMap { filter.headerSource == .original ? $0.requestHeaders : $0.sentHeaders }
        return Array(Set(captured.map { $0.name.lowercased() })
            .union(["content-type", "accept", "user-agent", "origin", "referer", "authorization", "cookie"])).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("筛选").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text("项目")
                    Picker("项目", selection: $filter.project) {
                        Text("全部项目").tag("")
                        ForEach(projects, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden()
                    Text("环境")
                    Picker("环境", selection: $filter.environment) {
                        Text("全部环境").tag("")
                        ForEach(environments, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden()
                }
                GridRow {
                    Text("结果")
                    Picker("结果", selection: $filter.outcome) {
                        Text("全部结果").tag(nil as CaptureRecord.Outcome?)
                        ForEach(CaptureRecord.Outcome.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                    }.labelsHidden()
                    Text("方法")
                    Picker("方法", selection: $filter.method) {
                        Text("全部方法").tag("")
                        ForEach(methods, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden()
                }
            }
            Divider()
            Text("请求 Header").font(.headline)
            HStack {
                Picker("请求版本", selection: $filter.headerSource) {
                    ForEach(CaptureHeaderSource.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden()
                Picker("条件组合", selection: $filter.headerCombination) {
                    ForEach(CaptureHeaderCombination.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden()
            }
            if !filter.headers.isEmpty {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach($filter.headers) { $condition in
                            HStack(spacing: 8) {
                                RequestHeaderNameField(text: $condition.name, suggestions: headerNames)
                                    .frame(width: 160).fixedSize(horizontal: false, vertical: true)
                                Picker("匹配方式", selection: $condition.operation) {
                                    ForEach(CaptureHeaderOperator.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                                }.labelsHidden().frame(width: 82)
                                TextField("值", text: $condition.value)
                                    .textFieldStyle(.roundedBorder).disabled(!condition.operation.needsValue)
                                    .accessibilityLabel("Header 值")
                                RequestHeaderRemoveButton {
                                    filter.headers.removeAll { $0.id == condition.id }
                                }.fixedSize()
                            }
                        }
                    }
                    // Native focus rings extend beyond their control bounds. Keep them
                    // inside the scroll viewport, including the first and last rows.
                    .padding(8)
                }.frame(height: min(240, CGFloat(filter.headers.count) * 40 + 4))
            }
            Button { filter.headers.append(CaptureHeaderCondition()) } label: {
                Label("添加条件", systemImage: "plus")
            }.disabled(filter.headers.count >= 16)
            Divider()
            HStack {
                Toggle("反向匹配", isOn: $filter.inverted).toggleStyle(.checkbox)
                    .help("反向匹配全部当前条件；不可判断的 Header 值不会被纳入")
                Spacer()
                Button("重置") { filter = CaptureRecordFilter() }
                    .disabled(filter == CaptureRecordFilter())
            }
        }
        .padding(20).frame(width: 560)
    }
}

/// Native bezels share a fixed hit area independent of their SF Symbol widths.
private struct RequestFilterActionButton: NSViewRepresentable {
    let symbol: String
    let label: String
    let help: String
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.performAction(_:)))
        button.imagePosition = .imageOnly
        button.controlSize = .regular
        if #available(macOS 26.0, *) {
            button.bezelStyle = .glass
            button.borderShape = .circle
        } else {
            button.bezelStyle = .circular
        }
        for orientation: NSLayoutConstraint.Orientation in [.horizontal, .vertical] {
            button.setContentHuggingPriority(.required, for: orientation)
            button.setContentCompressionResistancePriority(.required, for: orientation)
        }
        return button
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        CGSize(width: 32, height: 32)
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.toolTip = help
        button.setAccessibilityLabel(label)
        button.isEnabled = context.environment.isEnabled
    }
    @MainActor final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func performAction(_ sender: NSButton) {
            guard sender.isEnabled else { return }
            action()
        }
    }
}

private struct RequestHeaderNameField: NSViewRepresentable {
    @Binding var text: String
    let suggestions: [String]
    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeNSView(context: Context) -> NSComboBox {
        let field = NSComboBox()
        field.placeholderString = "Header 名称"
        field.setAccessibilityLabel("Header 名称")
        field.completes = true
        field.numberOfVisibleItems = 8
        field.setContentHuggingPriority(.required, for: .vertical)
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        field.delegate = context.coordinator
        return field
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSComboBox, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: nsView.intrinsicContentSize.height)
    }
    func updateNSView(_ field: NSComboBox, context: Context) {
        context.coordinator.text = $text
        if context.coordinator.suggestions != suggestions {
            context.coordinator.suggestions = suggestions
            field.removeAllItems(); field.addItems(withObjectValues: suggestions)
        }
        if field.stringValue != text { field.stringValue = text }
    }
    final class Coordinator: NSObject, NSComboBoxDelegate {
        var text: Binding<String>
        var suggestions: [String] = []
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSComboBox { text.wrappedValue = field.stringValue }
        }
        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSComboBox,
                  let value = field.objectValueOfSelectedItem as? String else { return }
            text.wrappedValue = value
        }
    }
}

/// A native circular action has a proper hit target even though the minus glyph is short.
private struct RequestHeaderRemoveButton: NSViewRepresentable {
    let remove: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(remove: remove) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.removeCondition(_:)))
        button.image = NSImage(systemSymbolName: "minus", accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.controlSize = .regular
        if #available(macOS 26.0, *) {
            button.bezelStyle = .glass
            button.borderShape = .circle
        } else {
            button.bezelStyle = .circular
        }
        for orientation: NSLayoutConstraint.Orientation in [.horizontal, .vertical] {
            button.setContentHuggingPriority(.required, for: orientation)
            button.setContentCompressionResistancePriority(.required, for: orientation)
        }
        button.toolTip = "移除 Header 条件"
        button.setAccessibilityLabel("移除 Header 条件")
        return button
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        let side = max(28, nsView.intrinsicContentSize.width, nsView.intrinsicContentSize.height)
        return CGSize(width: side, height: side)
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.remove = remove
        button.isEnabled = context.environment.isEnabled
    }
    @MainActor final class Coordinator: NSObject {
        var remove: () -> Void
        init(remove: @escaping () -> Void) { self.remove = remove }
        @objc func removeCondition(_ sender: NSButton) {
            guard sender.isEnabled else { return }
            remove()
        }
    }
}
