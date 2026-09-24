import SwiftUI

struct ApplicationsView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Table(model.applications, selection: $model.selectedApplicationIDs) {
                TableColumn("应用", value: \.name)
                TableColumn("标识", value: \.id)
            }
            .overlay {
                if model.applications.isEmpty {
                    ContentUnavailableView("没有可选择的应用", systemImage: "app.dashed", description: Text("打开需要调试的应用后，刷新列表。"))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("已选择 \(model.selectedApplicationIDs.count) 个应用")
                Text("按住 Command 可多选。当前仅记录选择，尚未开始拦截网络请求。")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding()
        }
        .toolbar {
            Button("刷新应用", systemImage: "arrow.clockwise") {
                model.refreshApplications()
            }
        }
        .task { model.refreshApplications() }
    }
}
