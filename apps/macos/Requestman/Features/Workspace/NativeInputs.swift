import AppKit

/// Shared defaults for native form inputs. Business validation stays with the caller.
@MainActor enum NativeInputMetrics {
    static let fieldHeight: CGFloat = 32
    static let textInset = NSSize(width: 6, height: 4)
    static let textFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
}

@MainActor
class ActionTextField: NSTextField, NSTextFieldDelegate {
    override class var cellClass: AnyClass? {
        get { ActionTextFieldCell.self }
        set {}
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: super.intrinsicContentSize.width, height: presentation == .form ? NativeInputMetrics.fieldHeight : super.intrinsicContentSize.height)
    }
    enum Presentation { case form, table }
    private let presentation: Presentation
    var onBeginEditing: (() -> Void)?
    var onChange: (String) -> Void
    var onSubmit: (() -> Void)?
    init(_ value: String = "", placeholder: String = "", presentation: Presentation = .form, onChange: @escaping (String) -> Void = { _ in }) {
        self.presentation = presentation
        self.onChange = onChange
        super.init(frame: .zero)
        stringValue = value; placeholderString = placeholder
        isEditable = true; isSelectable = true; isBezeled = true; bezelStyle = .squareBezel
        // The rounded bezel uses a system fill instead of the requested input background.
        appearance = NSAppearance(named: .aqua)
        drawsBackground = true; backgroundColor = .white; textColor = .black
        if presentation == .table {
            isBezeled = false; drawsBackground = false
            appearance = nil; textColor = .textColor
            font = .systemFont(ofSize: 13)
            lineBreakMode = .byTruncatingTail
        }
        usesSingleLineMode = true
        delegate = self
    }
    required init?(coder: NSCoder) { nil }
    func controlTextDidBeginEditing(_ notification: Notification) { onBeginEditing?() }
    func controlTextDidChange(_ notification: Notification) { onChange(stringValue) }
    func controlTextDidEndEditing(_ notification: Notification) { onChange(stringValue) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() else { return false }
        guard window?.makeFirstResponder(nil) == true else { return false }
        onSubmit?()
        return true
    }
}

/// Aligns text and the field editor within the taller native control.
@MainActor private final class ActionTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds bounds: NSRect) -> NSRect {
        var rect = super.drawingRect(forBounds: bounds)
        guard let font else { return rect }
        let height = min(rect.height, NSLayoutManager().defaultLineHeight(for: font))
        rect.origin.y += (rect.height - height) / 2
        rect.size.height = height
        return rect
    }
}

/// Editable native picker; programmatic updates never invoke the change callback.
@MainActor class ActionComboBox: NSComboBox, NSComboBoxDelegate {
    override var intrinsicContentSize: NSSize {
        NSSize(width: super.intrinsicContentSize.width, height: NativeInputMetrics.fieldHeight)
    }
    var onChange: (String) -> Void
    private var updatingSuggestions = false

    init(_ value: String = "", placeholder: String = "", suggestions: [String] = [],
         completes: Bool = false, onChange: @escaping (String) -> Void = { _ in }) {
        self.onChange = onChange
        super.init(frame: .zero)
        isEditable = true; isSelectable = true
        usesSingleLineMode = true
        self.completes = completes
        numberOfVisibleItems = 12
        drawsBackground = false
        placeholderString = placeholder
        addItems(withObjectValues: suggestions)
        stringValue = value
        delegate = self
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { nil }

    /// Preserve the current draft while refreshing the candidates.
    func setSuggestions(_ suggestions: [String]) {
        guard objectValues.compactMap({ $0 as? String }) != suggestions else { return }
        let draft = stringValue
        updatingSuggestions = true
        defer { updatingSuggestions = false }
        removeAllItems(); addItems(withObjectValues: suggestions)
        if stringValue != draft { stringValue = draft }
    }

    func controlTextDidChange(_ notification: Notification) { onChange(stringValue) }
    func controlTextDidEndEditing(_ notification: Notification) { onChange(stringValue) }
    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard !updatingSuggestions, let value = objectValueOfSelectedItem as? String else { return }
        stringValue = value
        onChange(value)
    }
}

/// Shared plain-text editor. Specialized editors can supply a native text view and refresh decorations.
@MainActor class ActionTextArea: NSScrollView, NSTextViewDelegate {
    let textView: NSTextView
    private let editable: Bool
    var onChange: (String) -> Void

    init(textView: NSTextView = InputTextView(), editable: Bool = true, revealFocus: Bool = false,
         onChange: @escaping (String) -> Void = { _ in }) {
        self.textView = textView
        self.editable = editable
        self.onChange = onChange
        super.init(frame: .zero)
        hasVerticalScroller = true; autohidesScrollers = true
        borderType = .bezelBorder; documentView = textView
        drawsBackground = true; backgroundColor = .textBackgroundColor
        textView.drawsBackground = true; textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.isRichText = false; textView.isEditable = editable; textView.isSelectable = true
        textView.font = NativeInputMetrics.textFont
        textView.isAutomaticQuoteSubstitutionEnabled = false; textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false; textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isHorizontallyResizable = false; textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]; textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NativeInputMetrics.textInset
        textView.textContainer?.lineFragmentPadding = 0
        textView.delegate = self; textView.allowsUndo = true
        if revealFocus {
            (textView as? InputTextView)?.focusChanged = { [weak self] focused in
                guard focused, let self, let parent = superview else { return }
                parent.scrollToVisible(convert(bounds.insetBy(dx: -6, dy: -6), to: parent))
            }
        }
    }
    required init?(coder: NSCoder) { nil }

    /// Disabled inputs cannot keep focus or selection; read-only viewers use editable: false instead.
    var isEnabled: Bool = true {
        didSet {
            textView.isEditable = isEnabled && editable; textView.isSelectable = isEnabled
            textView.setAccessibilityEnabled(isEnabled)
            if !isEnabled, window?.firstResponder === textView { window?.makeFirstResponder(nil) }
            textView.textColor = isEnabled ? .textColor : .disabledControlTextColor
            let color: NSColor = isEnabled ? .textBackgroundColor : .controlBackgroundColor
            textView.backgroundColor = color; backgroundColor = color; contentView.backgroundColor = color
        }
    }
    var string: String {
        get { textView.string }
        set {
            guard textView.string != newValue else { return }
            textView.string = newValue
            refreshTextPresentation()
        }
    }
    func refreshTextPresentation() {}
    func textDidChange(_ notification: Notification) {
        refreshTextPresentation()
        onChange(textView.string)
    }
    override func layout() {
        super.layout()
        let minimum = NSSize(width: 0, height: max(0, contentSize.height))
        if textView.minSize != minimum { textView.minSize = minimum }
    }
    override func scrollWheel(with event: NSEvent) {
        if contentView.documentRect.height <= contentView.bounds.height + 1 {
            nextResponder?.scrollWheel(with: event)
        } else { super.scrollWheel(with: event) }
    }
}

@MainActor class InputTextView: NSTextView {
    var focusChanged: ((Bool) -> Void)?
    override func scrollWheel(with event: NSEvent) {
        if let scroll = enclosingScrollView { scroll.scrollWheel(with: event) }
        else { super.scrollWheel(with: event) }
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusChanged?(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { focusChanged?(false) }
        return accepted
    }
}
