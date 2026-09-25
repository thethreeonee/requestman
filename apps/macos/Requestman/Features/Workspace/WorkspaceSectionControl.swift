import AppKit
import SwiftUI

/// AppKit owns the control's appearance, selection and sizing.
struct ToolbarSectionControl: NSViewRepresentable {
    var labels: [String]
    var accessibilityLabel: String
    var fillsAvailableWidth = false
    var controlSize: NSControl.ControlSize = .large
    @Binding var selection: Int

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: labels,
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectSection(_:))
        )
        control.segmentStyle = .automatic
        control.segmentDistribution = fillsAvailableWidth ? .fillEqually : .fit
        control.controlSize = controlSize
        if #available(macOS 26.0, *) {
            control.borderShape = .capsule
        }
        if #available(macOS 27.0, *) {
            control.role = .tabs
        }
        control.setAccessibilityLabel(accessibilityLabel)
        control.setContentHuggingPriority(fillsAvailableWidth ? .defaultLow : .required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .vertical)
        control.setContentCompressionResistancePriority(.required, for: .vertical)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        if control.selectedSegment != selection { control.selectedSegment = selection }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        let intrinsic = nsView.intrinsicContentSize
        guard fillsAvailableWidth, let width = proposal.width, width.isFinite else { return intrinsic }
        return CGSize(width: max(width, intrinsic.width), height: intrinsic.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<Int>

        init(selection: Binding<Int>) { self.selection = selection }

        @objc func selectSection(_ sender: NSSegmentedControl) {
            guard (0..<sender.segmentCount).contains(sender.selectedSegment) else { return }
            selection.wrappedValue = sender.selectedSegment
        }
    }
}
