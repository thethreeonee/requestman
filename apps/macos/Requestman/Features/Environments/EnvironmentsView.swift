import AppKit
import SwiftUI
import RequestmanCore

struct EnvironmentsView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        Group {
            if model.document.environments.isEmpty {
                ContentUnavailableView {
                    Label("还没有环境", systemImage: "externaldrive")
                } description: {
                    Text("创建 dev、staging 等环境，集中管理 API Key、Cookie 和目标地址。")
                } actions: {
                    Button("新建环境", action: model.addEnvironment)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EnvironmentSplitView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.disabled(!model.loaded)
    }
}

/// A settings pane split must not install navigation items in the settings window's toolbar.
private struct EnvironmentSplitView: NSViewControllerRepresentable {
    let model: WorkspaceModel

    func makeNSViewController(context: Context) -> NSSplitViewController {
        let controller = NSSplitViewController()
        controller.splitView.isVertical = true
        controller.splitView.dividerStyle = .thin

        let sidebar = NSHostingController(rootView: EnvironmentSidebar(model: model))
        let detail = NSHostingController(rootView: EnvironmentEditor(model: model))
        sidebar.sizingOptions = []
        detail.sizingOptions = []

        let sidebarItem = NSSplitViewItem(viewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 240
        sidebarItem.preferredThicknessFraction = 0.25
        sidebarItem.canCollapse = false
        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = 420
        controller.addSplitViewItem(sidebarItem)
        controller.addSplitViewItem(detailItem)
        return controller
    }

    func updateNSViewController(_ controller: NSSplitViewController, context: Context) {
        // Both hosted views observe the shared model; edits don't recreate their controllers.
    }
}

private struct EnvironmentSidebar: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $model.selectedEnvironmentID) {
                ForEach(model.document.environments) { environment in
                    HStack {
                        Text(environment.name)
                        Spacer()
                        if environment.id == model.document.selectedEnvironmentID {
                            Image(systemName: "checkmark").accessibilityLabel("正在使用")
                        }
                    }.tag(environment.id)
                }
            }.listStyle(.inset)
            HStack {
                Button("新建环境", systemImage: "plus", action: model.addEnvironment)
                Spacer()
            }.padding(12)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EnvironmentEditor: View {
    @Bindable var model: WorkspaceModel
    @State private var revealsValues = false

    var body: some View {
        Group {
            if let index = model.document.environments.firstIndex(where: { $0.id == model.selectedEnvironmentID }) {
                Form {
                    Section("环境") {
                        TextField("名称", text: $model.document.environments[index].name)
                        Button(model.document.selectedEnvironmentID == model.selectedEnvironmentID ? "正在使用" : "切换到此环境") {
                            model.document.selectedEnvironmentID = model.selectedEnvironmentID
                        }.disabled(model.document.selectedEnvironmentID == model.selectedEnvironmentID)
                    }
                    Section {
                        Toggle("显示值", isOn: $revealsValues)
                        ForEach($model.document.environments[index].variables) { $variable in
                            HStack {
                                TextField("变量名称", text: $variable.name)
                                if revealsValues { TextField("值", text: $variable.value) }
                                else { SecureField("值", text: $variable.value) }
                                Button("删除变量", systemImage: "minus.circle", role: .destructive) {
                                    let id = variable.id
                                    model.document.environments[index].variables.removeAll { $0.id == id }
                                }.labelStyle(.iconOnly).help("删除变量")
                            }
                        }
                        Button("添加变量", systemImage: "plus") {
                            model.document.environments[index].variables.append(NamedValue())
                        }
                    } header: {
                        Text("变量")
                    } footer: {
                        Text("使用 {{env.变量名}} 引用。切换环境仅影响新请求；进行中的请求保留原环境快照。")
                    }
                    Section {
                        Button("删除环境", role: .destructive) {
                            let id = model.document.environments[index].id
                            model.document.environments.remove(at: index)
                            if model.document.selectedEnvironmentID == id { model.document.selectedEnvironmentID = nil }
                            model.selectedEnvironmentID = model.document.environments.first?.id
                        }
                    } footer: {
                        Text("环境保存在本机工作区文件中。变量名称应唯一；同名时使用最后一个值。")
                    }
                }.formStyle(.grouped)
            } else {
                ContentUnavailableView("选择一个环境", systemImage: "externaldrive", description: Text("从左侧选择环境以编辑变量。"))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
