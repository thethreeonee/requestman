import AppKit
import CodeEditTextView

/// AppKit editor shared by body and script forms. Layout and input belong to CodeEditTextView.
@MainActor public final class CodeEditorView: NSScrollView, GutterViewDelegate {
    public enum Language: String, Sendable { case json, javascript, plaintext }
    public let textView: TextView
    public let language: Language
    public var onChange: (String) -> Void
    /// Business annotations, independent of the syntax grammar (for example template variables).
    public var annotationRanges: ((String) -> [NSRange])? { didSet { scheduleHighlight() } }
    private var gutter: GutterView!
    private let highlighter = SyntaxHighlighter()
    private var highlightTask: Task<Void, Never>?
    private var generation = 0
    private var assigningText = false

    public init(language: Language, onChange: @escaping (String) -> Void = { _ in }) {
        self.language = language
        self.onChange = onChange
        textView = TextView(string: "", font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                            textColor: .textColor, lineHeightMultiplier: 1.4, wrapLines: true,
                            isEditable: true, isSelectable: true, letterSpacing: 1)
        super.init(frame: .zero)
        borderType = .noBorder
        hasVerticalScroller = true; hasHorizontalScroller = false; autohidesScrollers = true
        drawsBackground = true; backgroundColor = .textBackgroundColor
        clipsToBounds = true; wantsLayer = true
        layer?.cornerRadius = 8; layer?.masksToBounds = true
        textView.overscrollAmount = 0
        textView.allowsUndo = true
        documentView = textView
        gutter = GutterView(font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                            textColor: .secondaryLabelColor, selectedTextColor: .labelColor,
                            textView: textView, delegate: self)
        gutter.backgroundColor = .textBackgroundColor
        gutter.edgeInsets = .init(leading: 8, trailing: 8)
        gutter.backgroundEdgeInsets = .init(leading: 0, trailing: 0)
        gutter.translatesAutoresizingMaskIntoConstraints = true
        addFloatingSubview(gutter, for: .horizontal)
        gutter.updateWidthIfNeeded()
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(invalidateGutter), name: NSView.boundsDidChangeNotification, object: contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged), name: TextView.textDidChangeNotification, object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(invalidateGutter), name: TextSelectionManager.selectionChangedNotification, object: textView.selectionManager)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { highlightTask?.cancel(); NotificationCenter.default.removeObserver(self) }

    public var string: String {
        get { textView.string }
        set {
            guard newValue != string else { return }
            assigningText = true
            textView.string = newValue
            textView.selectionManager.setSelectedRange(NSRange(location: 0, length: 0))
            textView._undoManager?.clearStack()
            assigningText = false
            scheduleHighlight(); needsLayout = true
        }
    }

    /// An explicit user operation, kept in the editor's undo history.
    public func replaceText(with value: String) {
        guard textView.isEditable, !textView.hasMarkedText(), value != string else { return }
        textView.undoManager?.beginUndoGrouping()
        textView.replaceCharacters(in: textView.documentRange, with: value)
        textView.undoManager?.endUndoGrouping()
    }

    public func gutterViewWidthDidUpdate() {
        textView.textInsets = .init(left: (gutter?.frame.width ?? 40) + 8, right: 8)
        needsLayout = true
    }

    override public func layout() {
        super.layout()
        textView.updateFrameIfNeeded()
        gutter.updateWidthIfNeeded()
        gutter.frame.size.height = max(contentSize.height, textView.frame.height)
        gutter.needsDisplay = true
    }

    override public func scrollWheel(with event: NSEvent) {
        if contentView.documentRect.height <= contentView.bounds.height + 1 {
            nextResponder?.scrollWheel(with: event)
        } else { super.scrollWheel(with: event) }
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        gutter?.needsDisplay = true
        scheduleHighlight()
    }

    @objc private func invalidateGutter() { gutter.needsDisplay = true }
    @objc private func textChanged() {
        guard !assigningText else { return }
        scheduleHighlight(); needsLayout = true
        onChange(string)
    }

    private func scheduleHighlight() {
        generation += 1; highlightTask?.cancel()
        let version = generation, source = string, language = language
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let worker = highlighter
        highlightTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            guard !Task.isCancelled, self?.textView.hasMarkedText() == false else { return }
            let colors = await worker.highlight(source, language: language.rawValue, dark: dark)
            guard !Task.isCancelled, let self, version == generation,
                  source == string, !textView.hasMarkedText() else { return }
            let storage = textView.textStorage!
            let range = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
            storage.removeAttribute(.backgroundColor, range: range)
            for run in colors {
                storage.addAttribute(.foregroundColor, value: NSColor(srgbRed: run.red, green: run.green, blue: run.blue, alpha: run.alpha), range: run.range)
            }
            for annotation in annotationRanges?(source) ?? [] where annotation.location >= 0 && NSMaxRange(annotation) <= storage.length {
                storage.addAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.12), range: annotation)
            }
            storage.endEditing()
            textView.needsDisplay = true
        }
    }
}
