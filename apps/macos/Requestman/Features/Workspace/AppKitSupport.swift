import AppKit
import Observation

/// Re-registers one-shot model observation without polling or replacing the view hierarchy.
@MainActor
class ObservedViewController: NSViewController {
    private var observationGeneration = 0
    private var observing = true

    init() { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        observeModel()
    }

    func refresh() {}

    final func observeModel() {
        guard observing, isViewLoaded else { return }
        observationGeneration += 1
        let generation = observationGeneration
        withObservationTracking { refresh() } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observing, self.observationGeneration == generation else { return }
                self.observeModel()
            }
        }
    }

    func stopObserving() { observing = false; observationGeneration += 1 }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
enum NativeUI {
    static func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                      secondary: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    static func stack(_ views: [NSView], vertical: Bool = true, spacing: CGFloat = 10) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = vertical ? .vertical : .horizontal
        stack.alignment = vertical ? .leading : .centerY
        stack.spacing = spacing
        stack.detachesHiddenViews = true
        return stack
    }

    static func pin(_ child: NSView, to parent: NSView,
                    insets: NSEdgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)) {
        child.translatesAutoresizingMaskIntoConstraints = false
        if child.superview !== parent { parent.addSubview(child) }
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: insets.left),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -insets.right),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: insets.top),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -insets.bottom)
        ])
    }

    static func separator() -> NSBox {
        let box = NSBox(); box.boxType = .separator; return box
    }
}

@MainActor
final class ActionButton: NSButton {
    var handler: () -> Void
    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self; self.action = #selector(invoke(_:))
    }
    required init?(coder: NSCoder) { nil }
    @objc private func invoke(_ sender: NSButton) { guard isEnabled else { return }; handler() }
}

@MainActor
final class ActionTextField: NSTextField, NSTextFieldDelegate {
    var onChange: (String) -> Void
    init(_ value: String = "", placeholder: String = "", onChange: @escaping (String) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        stringValue = value; placeholderString = placeholder
        isEditable = true; isSelectable = true; isBezeled = true; bezelStyle = .roundedBezel
        delegate = self
    }
    required init?(coder: NSCoder) { nil }
    func controlTextDidChange(_ notification: Notification) { onChange(stringValue) }
}

@MainActor
final class ActionPopUpButton: NSPopUpButton {
    var onChange: (Int) -> Void
    init(items: [String], onChange: @escaping (Int) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero, pullsDown: false)
        addItems(withTitles: items)
        target = self; action = #selector(selectItemAction(_:))
    }
    required init?(coder: NSCoder) { nil }
    @objc private func selectItemAction(_ sender: NSPopUpButton) {
        guard isEnabled, indexOfSelectedItem >= 0 else { return }
        onChange(indexOfSelectedItem)
    }
}
