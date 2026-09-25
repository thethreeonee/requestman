import SwiftUI
import RequestmanCore

struct RequestsView: View {
    let model: WorkspaceModel
    var body: some View { ExecutionRecordsView(model: model, history: model.history) }
}

private struct ExecutionRecordsView: View {
    let model: WorkspaceModel
    @Bindable var history: ExecutionHistoryModel
    private var recordSelection: Binding<UUID?> {
        Binding(get: { history.selectedID }, set: { history.selectedID = $0 })
    }

    var body: some View {
        let records = history.filtered
        VStack(spacing: 0) {
            RequestFilterControls(filter: $history.filter, records: history.records, paused: history.paused,
                                  toggleRecording: { model.setRecordingPaused(!history.paused) },
                                  clear: { model.clearHistory() })
            if history.paused || history.dropped > 0 {
                HStack {
                    if history.paused { Label("记录已暂停，代理继续工作", systemImage: "pause.circle") }
                    if history.dropped > 0 { Text("高负载下已丢弃 \(history.dropped) 条待显示记录") }
                    Spacer()
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 8)
            }
            Divider()
            RequestRecordsTable(records: records, selectedID: recordSelection)
                .overlay {
                    if records.isEmpty {
                        ContentUnavailableView(history.records.isEmpty ? "等待请求" : "没有符合条件的记录", systemImage: "clock",
                            description: Text(history.records.isEmpty ? "启动捕获，将浏览器连接到本地代理后，请求会显示在这里。" : "调整搜索或筛选条件。"))
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .onAppear { history.selectedID = nil }
    }
}
