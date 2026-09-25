import SwiftUI
import RequestmanCore

struct RequestsView: View {
    let model: WorkspaceModel
    var body: some View {
        ExecutionRecordsView(model: model, history: model.history)
            .toolbar(removing: .sidebarToggle)
    }
}

private struct ExecutionRecordsView: View {
    let model: WorkspaceModel
    @Bindable var history: ExecutionHistoryModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var detailAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.25)
    }

    private var recordSelection: Binding<UUID?> {
        Binding(
            get: { history.selectedID },
            set: { id in withAnimation(detailAnimation) { history.selectedID = id } }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("请求日志").font(.title2.bold())
                Text("\(history.records.count)").foregroundStyle(.secondary).monospacedDigit()
                Button { model.setRecordingPaused(!history.paused) } label: {
                    Label(history.paused ? "继续记录" : "暂停记录", systemImage: history.paused ? "play" : "pause")
                }
                Button { model.clearHistory() } label: { Label("清空", systemImage: "trash") }.disabled(history.records.isEmpty)
                Spacer()
            }.padding(.horizontal, 20).padding(.vertical, 12)
            HStack(spacing: 12) {
                Picker("项目", selection: $history.project) {
                    Text("全部项目").tag("")
                    ForEach(Array(Set(history.records.map(\.project))).sorted(), id: \.self) { Text($0).tag($0) }
                }.frame(maxWidth: 200)
                Picker("环境", selection: $history.environment) {
                    Text("全部环境").tag("")
                    ForEach(Array(Set(history.records.map(\.environment))).sorted(), id: \.self) { Text($0).tag($0) }
                }.frame(maxWidth: 200)
                Picker("结果", selection: $history.outcome) {
                    Text("全部结果").tag(nil as CaptureRecord.Outcome?)
                    ForEach(CaptureRecord.Outcome.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                }.frame(maxWidth: 185)
                Spacer(minLength: 0)
            }.padding(.horizontal, 24).padding(.bottom, 18)
            if history.paused || history.dropped > 0 {
                HStack {
                    if history.paused { Label("记录已暂停，代理继续工作", systemImage: "pause.circle") }
                    if history.dropped > 0 { Text("高负载下已丢弃 \(history.dropped) 条待显示记录") }
                    Spacer()
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 10)
            }
            Divider()
            Table(history.filtered, selection: recordSelection) {
                TableColumn("时间") { record in Text(record.startedAt, format: .dateTime.hour().minute().second()).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }.width(68)
                TableColumn("请求") { record in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 7) { Text(record.method).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(record.method == "POST" ? .orange : .blue); Text(record.url).lineLimit(1).truncationMode(.middle) }
                        Text(record.outcome.rawValue).font(.caption).foregroundStyle(outcomeColor(record.outcome))
                    }.padding(.vertical, 5)
                }.width(min: 180, ideal: 290)
                TableColumn("项目 / 请求修改") { record in
                    VStack(alignment: .leading, spacing: 5) { Text(record.workflow).lineLimit(1); Text(record.project).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }.width(min: 110, ideal: 150)
                TableColumn("环境", value: \.environment).width(75)
                TableColumn("状态") { record in Text(record.status.map(String.init) ?? "—").foregroundStyle(record.outcome == .failed ? .red : .green).monospacedDigit() }.width(45)
                TableColumn("耗时") { record in Text("\(Int(record.duration * 1000)) ms").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }.width(70)
            }
            .overlay {
                if history.filtered.isEmpty {
                    ContentUnavailableView(history.records.isEmpty ? "等待请求" : "没有符合条件的记录", systemImage: "clock", description: Text(history.records.isEmpty ? "启动捕获，将 Chrome 连接到本地代理后，请求会显示在这里。" : "调整搜索或筛选条件。"))
                }
            }.frame(minWidth: 690, maxWidth: .infinity)
        }
        .onAppear { history.selectedID = nil }
    }
    private func outcomeColor(_ outcome: CaptureRecord.Outcome) -> Color {
        switch outcome { case .failed: .red; case .modified: .blue; case .mocked: .purple; case .tunnel: .secondary; case .forwarded: .green }
    }
}

struct RequestInspectorView: View {
    let history: ExecutionHistoryModel

    var body: some View {
        VStack(spacing: 0) {
            Text("请求详情")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            if let record = history.selected {
                RecordDetailView(record: record)
            }
        }
    }
}

private struct RecordDetailView: View {
    let record: CaptureRecord
    @State private var tab = 0

    var body: some View {
        Form {
            Section("执行详情") {
                LabeledContent("请求", value: "\(record.method) \(record.url)")
                    .textSelection(.enabled)
                LabeledContent("结果", value: record.outcome.rawValue)
                LabeledContent("耗时", value: "\(Int(record.duration * 1000)) ms")
                Picker("详情", selection: $tab) {
                    Text("执行过程").tag(0)
                    Text("请求").tag(1)
                    Text("响应").tag(2)
                }.pickerStyle(.segmented).labelsHidden()
            }
            if tab == 0 {
                Section("匹配") {
                    LabeledContent("项目", value: record.project)
                    LabeledContent("请求修改", value: record.workflow)
                    LabeledContent("环境", value: record.environment)
                }
                Section("执行步骤") {
                    Label("接收请求", systemImage: "arrow.down.circle")
                    ForEach(Array(record.steps.enumerated()), id: \.offset) { _, step in
                        Label(step, systemImage: "checkmark.circle")
                    }
                    Label(record.outcome == .tunnel ? "CONNECT 已建立 · HTTPS 未解密" : "\(record.status.map(String.init) ?? "—") · \(record.outcome.rawValue)", systemImage: record.error == nil ? "checkmark.circle" : "xmark.circle")
                    if let error = record.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
            } else if tab == 1 {
                Section("目标地址") {
                    Text("\(record.sentMethod) \(record.finalURL)")
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    LabeledContent("接收 Body", value: "\(record.requestBytes) 字节")
                }
                headerSection("原始请求", fields: record.requestHeaders)
                headerSection("发往服务器", fields: record.sentHeaders)
            } else {
                headerSection("服务器返回", fields: record.receivedHeaders)
                headerSection("发往客户端", fields: record.responseHeaders)
                LabeledContent("接收 / Mock Body", value: "\(record.responseBytes) 字节")
            }
            if tab != 0 {
                Section {
                    Text(record.outcome == .tunnel ? "加密隧道不读取内部请求和响应。" : "记录保存元数据，不缓存 Body。常见凭据 Header 已隐藏。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.formStyle(.grouped)
    }

    private func headerSection(_ title: String, fields: [HTTPField]) -> some View {
        Section(title) {
            if fields.isEmpty { Text("无 Header").foregroundStyle(.secondary) }
            ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                LabeledContent(field.name, value: field.value)
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
        }
    }
}
