import AppKit
import SwiftUI

/// AppKit owns selection and sizing; the toolbar supplies the glass backing.
struct WorkspaceSectionControl: NSViewRepresentable {
    @Binding var selection: WorkspaceSection

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: WorkspaceSection.allCases.map(\.title),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectSection(_:))
        )
        control.segmentStyle = .automatic
        control.segmentDistribution = .fit
        control.controlSize = .regular
        if #available(macOS 26.0, *) {
            control.borderShape = .capsule
        }
        control.setAccessibilityLabel("工作区")
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        control.selectedSegment = WorkspaceSection.allCases.firstIndex(of: selection) ?? 0
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<WorkspaceSection>

        init(selection: Binding<WorkspaceSection>) { self.selection = selection }

        @objc func selectSection(_ sender: NSSegmentedControl) {
            guard WorkspaceSection.allCases.indices.contains(sender.selectedSegment) else { return }
            selection.wrappedValue = WorkspaceSection.allCases[sender.selectedSegment]
        }
    }
}
