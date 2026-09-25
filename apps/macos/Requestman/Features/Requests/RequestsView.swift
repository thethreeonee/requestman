import SwiftUI
import RequestmanCore

struct RequestsView: View {
    let model: WorkspaceModel
    var body: some View {
        ExecutionRecordsView(model: model, history: model.history)
    }
}

private struct ExecutionRecordsView: View {
    let model: WorkspaceModel
    @Bindable var history: ExecutionHistoryModel
    private var recordSelection: Binding<UUID?> {
        Binding(
            get: { history.selectedID },
            set: { history.selectedID = $0 }
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
            RequestRecordsTable(records: history.filtered, selectedID: recordSelection)
                .overlay {
                    if history.filtered.isEmpty {
                        ContentUnavailableView(history.records.isEmpty ? "等待请求" : "没有符合条件的记录", systemImage: "clock", description: Text(history.records.isEmpty ? "启动捕获，将浏览器连接到本地代理后，请求会显示在这里。" : "调整搜索或筛选条件。"))
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .onAppear { history.selectedID = nil }
    }
}
