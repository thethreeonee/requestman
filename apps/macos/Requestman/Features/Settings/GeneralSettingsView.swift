import AppKit
import SwiftUI
import RequestmanCore

struct GeneralSettingsView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        Form {
            Section {
                Picker("启动方式", selection: $model.captureMode) {
                    Text(CaptureMode.systemProxy.title).tag(CaptureMode.systemProxy)
                    Text(CaptureMode.browser.title).tag(CaptureMode.browser)
                }
                .pickerStyle(.menu)
                .disabled(!model.loaded || model.isTransitioning)
            } header: {
                Text("启动")
            } footer: {
                Text("全局接管会修改系统 HTTP/HTTPS 代理；仅启动浏览器只为所选浏览器打开代理调试窗口。启动方式的修改将在下次启动时生效。")
                    .font(.footnote)
            }
            Section {
                if model.installedBrowsers.isEmpty {
                    Text(model.isDiscoveringBrowsers ? "正在查找浏览器…" : "未找到已安装的 Chromium 浏览器。")
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("浏览器") {
                        BrowserPopUpButton(
                            options: model.installedBrowsers.map {
                                BrowserPickerOption(id: $0.id, title: model.browserDisplayName($0), applicationURL: $0.applicationURL)
                            },
                            selection: $model.selectedBrowserID
                        )
                        .frame(minWidth: 200, maxWidth: 360)
                    }
                    .disabled(!model.loaded || model.isTransitioning || model.isDiscoveringBrowsers)
                }
                Button("刷新列表") { Task { await model.refreshBrowsers() } }
                    .disabled(model.isTransitioning || model.isDiscoveringBrowsers)
            } header: {
                Text("浏览器")
            } footer: {
                Text("列出已安装的 Chrome 及同类 Chromium 浏览器。").font(.footnote)
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshBrowsers() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshBrowsers() }
        }
    }
}

private struct BrowserPickerOption: Equatable {
    let id: String
    let title: String
    let applicationURL: URL
}

private struct BrowserPopUpButton: NSViewRepresentable {
    let options: [BrowserPickerOption]
    @Binding var selection: String

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectBrowser(_:))
        button.autoenablesItems = false
        button.imagePosition = .imageLeft
        button.cell?.lineBreakMode = .byTruncatingMiddle
        button.setAccessibilityLabel("浏览器")
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        if context.coordinator.options != options {
            button.removeAllItems()
            for option in options {
                let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
                let icon = NSWorkspace.shared.icon(forFile: option.applicationURL.path).copy() as? NSImage
                icon?.size = NSSize(width: 18, height: 18)
                item.image = icon
                item.representedObject = option.id
                button.menu?.addItem(item)
            }
            context.coordinator.options = options
        }
        button.selectItem(at: options.firstIndex { $0.id == selection } ?? -1)
        button.isEnabled = context.environment.isEnabled
        button.setAccessibilityValue(button.selectedItem?.title ?? "")
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: nsView.intrinsicContentSize.height)
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<String>
        var options: [BrowserPickerOption] = []

        init(selection: Binding<String>) { self.selection = selection }

        @objc func selectBrowser(_ sender: NSPopUpButton) {
            guard let id = sender.selectedItem?.representedObject as? String else { return }
            selection.wrappedValue = id
        }
    }
}
