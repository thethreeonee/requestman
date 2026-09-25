import AppKit
import SwiftUI

enum WorkspaceSettingsSection: CaseIterable {
    case general, connection, environments

    var title: String {
        switch self { case .general: "通用"; case .connection: "连接"; case .environments: "环境管理" }
    }
}

struct WorkspaceSettingsView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            switch model.settingsSection {
            case .general:
                GeneralSettingsView(model: model)
            case .connection:
                ConnectionSettingsView(model: model)
            case .environments:
                EnvironmentsView(model: model)
            }
        }
        .frame(width: 800, height: 540)
        .background(SettingsWindowAppearance())
        .navigationTitle("设置")
        .toolbar {
            if #available(macOS 26.0, *) {
                sectionTabs.sharedBackgroundVisibility(.visible)
            } else {
                sectionTabs
            }
        }
    }

    private var sectionTabs: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            ToolbarSectionControl(labels: WorkspaceSettingsSection.allCases.map(\.title), accessibilityLabel: "设置",
                                  selection: Binding(
                                    get: { WorkspaceSettingsSection.allCases.firstIndex(of: model.settingsSection) ?? 0 },
                                    set: { model.settingsSection = WorkspaceSettingsSection.allCases[$0] }
                                  ))
                .fixedSize()
        }
    }
}

/// Settings can apply its preference toolbar style after the scene modifier.
/// Configure the attached window after SwiftUI finishes its layout pass.
private struct SettingsWindowAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowAppearanceView { WindowAppearanceView() }

    func updateNSView(_ nsView: WindowAppearanceView, context: Context) {
        nsView.scheduleAppearanceUpdate()
    }

    final class WindowAppearanceView: NSView {
        private var updateScheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleAppearanceUpdate()
        }

        override func layout() {
            super.layout()
            scheduleAppearanceUpdate()
        }

        func scheduleAppearanceUpdate() {
            guard window != nil, !updateScheduled else { return }
            updateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updateScheduled = false
                guard let window = self.window else { return }
                if window.toolbarStyle != .unified {
                    window.toolbarStyle = .unified
                }
                if window.titleVisibility != .hidden {
                    window.titleVisibility = .hidden
                }
            }
        }
    }
}
