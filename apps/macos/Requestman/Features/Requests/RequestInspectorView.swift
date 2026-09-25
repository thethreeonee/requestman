import AppKit
import SwiftUI
import RequestmanCore

struct RequestInspectorView: View {
    let history: ExecutionHistoryModel
    let isPresented: Bool
    @State private var tab: RequestDetailTab = .requestHeaders

    var body: some View {
        VStack(spacing: 0) {
            if let record = history.selected {
                RequestDetailView(record: record, tab: $tab, isPresented: isPresented).id(record.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct RequestDetailView: View {
    let record: CaptureRecord
    @Binding var tab: RequestDetailTab
    let isPresented: Bool
    @State private var visited: Set<RequestDetailTab> = []
    @State private var showsURL = false
    @State private var showsRule = false
    @State private var showsQuery = false

    var body: some View {
        VStack(spacing: 0) {
            summary.padding(16)
            ToolbarSectionControl(
                labels: RequestDetailTab.allCases.map(\.title), accessibilityLabel: "请求数据",
                selection: Binding(
                    get: { RequestDetailTab.allCases.firstIndex(of: tab) ?? 0 },
                    set: { tab = RequestDetailTab.allCases[$0] }
                )
            )
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16).padding(.bottom, 10)
            // Keep visited panes mounted so native scrolling, expansion and search survive a tab switch.
            ZStack {
                ForEach(RequestDetailTab.allCases) { item in
                    if visited.contains(item) || item == tab {
                        RequestPayloadView(record: record, tab: item, isActive: isPresented && item == tab)
                            .opacity(item == tab ? 1 : 0)
                            .allowsHitTesting(item == tab)
                            .accessibilityHidden(item != tab)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { visited.insert(tab) }
        .onChange(of: tab) { _, value in
            visited.insert(value)
            // Hidden native panes must not retain the keyboard copy target.
            if !(NSApp.keyWindow?.firstResponder is NSSegmentedControl) {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
        .onChange(of: isPresented) { _, value in
            if !value { showsURL = false }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { showsURL = true } label: {
                Text(record.url)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help(record.url)
            .accessibilityLabel("请求 URL").accessibilityValue(record.url)
            .popover(isPresented: $showsURL) { RequestURLDetails(record: record) }
            if hasQueryParameters {
                Button { showsQuery.toggle() } label: {
                    HStack(spacing: 5) {
                        Text("查询参数")
                        Text(queryCount == finalQueryCount ? "\(queryCount)" : "\(queryCount) → \(finalQueryCount)")
                            .monospacedDigit().foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption2)
                    }.font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help("查看 URL 中的查询参数，与请求正文分开展示")
                .popover(isPresented: $showsQuery) { RequestQueryDetails(record: record) }
            }
            HStack(spacing: 10) {
                Text(record.method).fontWeight(.medium)
                Text(statusText).foregroundStyle(statusColor)
                Divider().frame(height: 12)
                Text("\(Int(record.duration * 1000)) ms").monospacedDigit()
                Divider().frame(height: 12)
                Text("响应 \(ByteCountFormatter.string(fromByteCount: Int64(record.responseBytes), countStyle: .file))")
                    .lineLimit(1)
            }.font(.system(size: 12)).foregroundStyle(.secondary)
            if record.matchedWorkflowID != nil {
                Button { showsRule.toggle() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(.tint)
                        Text(record.workflow).lineLimit(1)
                        Text(record.project).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12)).padding(.top, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("查看命中规则与执行步骤")
                .popover(isPresented: $showsRule) { ruleDetails }
            }
            if let error = record.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.red).lineLimit(2).help(error)
            }
        }
    }

    private var queryCount: Int {
        URLComponents(string: record.url)?.queryItems?.count ?? 0
    }

    private var hasQueryParameters: Bool {
        queryCount > 0 || finalQueryCount > 0
    }

    private var finalQueryCount: Int {
        URLComponents(string: record.finalURL)?.queryItems?.count ?? 0
    }

    private var statusText: String {
        guard let status = record.status else { return record.outcome.rawValue }
        let reasons = [200: "OK", 201: "Created", 202: "Accepted", 204: "No Content",
                       301: "Moved Permanently", 302: "Found", 304: "Not Modified", 307: "Temporary Redirect",
                       308: "Permanent Redirect", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                       404: "Not Found", 429: "Too Many Requests", 500: "Internal Server Error",
                       502: "Bad Gateway", 503: "Service Unavailable", 504: "Gateway Timeout"]
        return reasons[status].map { "\(status) \($0)" } ?? String(status)
    }

    private var statusColor: Color {
        if record.error != nil { return .red }
        guard let status = record.status else { return .secondary }
        if status >= 400 { return .red }
        if status >= 300 { return .secondary }
        return .green
    }

    private var ruleDetails: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(record.workflow).font(.headline)
                LabeledContent("项目", value: record.project)
                LabeledContent("环境", value: record.environment)
                Divider()
                Text("执行步骤").font(.subheadline.weight(.medium))
                if record.steps.isEmpty { Text("没有执行步骤").foregroundStyle(.secondary) }
                ForEach(Array(record.steps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). \(step)").textSelection(.enabled)
                }
                Text(record.outcome.rawValue).foregroundStyle(.secondary)
            }.font(.system(size: 12)).padding(16)
        }.frame(width: 340).frame(maxHeight: 360)
    }
}

private struct RequestURLDetails: View {
    let record: CaptureRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("请求 URL").font(.headline)
                Spacer()
                Button("复制完整 URL") { RequestClipboard.copy(record.url) }
                    .disabled(record.urlWasTruncated)
                    .help(record.urlWasTruncated ? "URL 记录已截断，无法复制完整地址" : "复制完整 URL")
            }
            if record.urlWasTruncated {
                Text("URL 超出记录上限，以下仅显示已记录的部分，地址不完整。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(record.url)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
        }
        .padding(16)
        .frame(width: 480)
    }
}

/// URL query items remain separate from the HTTP entity body, including GET
/// requests with no body. Repeated parameter names retain their original order.
private struct RequestQueryDetails: View {
    let record: CaptureRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("查询参数").font(.headline)
                querySection("原始 URL", url: record.url, truncated: record.urlWasTruncated)
                if URLComponents(string: record.url)?.percentEncodedQuery != URLComponents(string: record.finalURL)?.percentEncodedQuery {
                    Divider()
                    querySection("最终 URL", url: record.finalURL, truncated: record.finalURLWasTruncated)
                }
            }.padding(16)
        }.frame(width: 420).frame(maxHeight: 440)
    }

    private func querySection(_ title: String, url: String, truncated: Bool) -> some View {
        let items = URLComponents(string: url)?.queryItems ?? []
        return VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            if items.isEmpty {
                Text("无查询参数").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                URLParameterRow(name: item.name, value: item.value ?? "")
            }
            if truncated {
                Text("URL 超出记录上限，查询参数可能不完整。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct URLParameterRow: View {
    let name: String
    let value: String
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(alignment: .top) {
            Text(name).frame(width: 120, alignment: .leading)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button { RequestClipboard.copy(value) } label: { Label("复制 \(name)", systemImage: "doc.on.doc") }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .opacity(hovering ? 1 : 0).help("复制字段值")
                .allowsHitTesting(hovering)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: hovering)
        }
        .font(.system(size: 12, design: .monospaced)).padding(.vertical, 3)
        .contentShape(Rectangle()).onHover { hovering = $0 }
        .contextMenu { Button("复制字段值") { RequestClipboard.copy(value) } }
    }
}

enum RequestClipboard {
    @MainActor static func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
