import AppKit

/// The same system control is used by settings and inspector content tabs.
@MainActor
final class ToolbarSectionControl: NSSegmentedControl {
    var onChange: (Int) -> Void

    init(labels: [String], accessibilityLabel: String, fillsAvailableWidth: Bool = false,
         controlSize: NSControl.ControlSize = .large, onChange: @escaping (Int) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        segmentCount = labels.count
        for (index, title) in labels.enumerated() { setLabel(title, forSegment: index) }
        trackingMode = .selectOne
        segmentStyle = .automatic
        segmentDistribution = fillsAvailableWidth ? .fillEqually : .fit
        self.controlSize = controlSize
        if #available(macOS 26.0, *) { borderShape = .capsule }
        if #available(macOS 27.0, *) { role = .tabs }
        setAccessibilityLabel(accessibilityLabel)
        setContentHuggingPriority(fillsAvailableWidth ? .defaultLow : .required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        target = self; action = #selector(selectSection(_:))
    }
    required init?(coder: NSCoder) { nil }
    @objc private func selectSection(_ sender: NSSegmentedControl) {
        guard (0..<segmentCount).contains(selectedSegment) else { return }
        onChange(selectedSegment)
    }
}
