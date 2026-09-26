import AppKit

/// Tokens retain their original spelling; formatting never round-trips numbers through Foundation.
enum BodyJSONPresentation {
    static func formatted(_ text: String) -> String? {
        let original = JSONSyntax.tokens(text)
        var items = original
        // Normalize object-literal keys and trailing commas without evaluating JavaScript.
        // Keep the original whitespace for validation so invalid adjacent values cannot be joined.
        let validation = NSMutableString(string: text)
        for index in original.indices.reversed() {
            let item = original[index]
            let next = index + 1 < original.count ? original[index + 1].text : ""
            let previous = index > 0 ? original[index - 1].text : ""
            if item.text == ",", ["}", "]"].contains(next), !["[", "{", ",", ":"].contains(previous) {
                validation.replaceCharacters(in: item.range, with: "")
                items.remove(at: index)
            } else if next == ":", JSONSyntax.isIdentifier(item.text) {
                let quoted = "\"" + item.text + "\""
                validation.replaceCharacters(in: item.range, with: quoted)
                items[index].text = quoted
            } else if item.text.hasPrefix("{{") {
                validation.replaceCharacters(in: item.range, with: "null")
            }
        }
        guard (try? JSONSerialization.jsonObject(with: Data((validation as String).utf8), options: [.fragmentsAllowed])) != nil else { return nil }
        var output = "", depth = 0
        func newline() { output += "\n" + String(repeating: "  ", count: depth) }
        for (index, item) in items.enumerated() {
            let previous = index > 0 ? items[index - 1].text : ""
            let next = index + 1 < items.count ? items[index + 1].text : ""
            switch item.text {
            case "{", "[":
                output += item.text; depth += 1
                if next != (item.text == "{" ? "}" : "]") { newline() }
            case "}", "]":
                depth = max(0, depth - 1)
                if previous != (item.text == "}" ? "{" : "[") { newline() }
                output += item.text
            case ",": output += ","; newline()
            case ":": output += ": "
            default: output += item.text
            }
        }
        return output
    }


}

/// Native ruler annotations follow logical lines, including wrapped lines and the final empty line.
@MainActor final class BodyLineRuler: NSRulerView {
    private(set) var lineStarts = [0]
    override var isFlipped: Bool { true }

    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        ruleThickness = 38
        reservedThicknessForMarkers = 0; reservedThicknessForAccessoryView = 0
        setAccessibilityElement(false)
        if let clip = scrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: clip)
        }
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func scrolled() { needsDisplay = true }

    func updateLines() {
        guard let text = clientView as? NSTextView else { return }
        let source = text.string as NSString
        lineStarts = [0]
        var position = 0
        while position < source.length {
            var end = 0, contentsEnd = 0
            source.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: position, length: 0))
            if end > contentsEnd { lineStarts.append(end) }
            position = end
        }
        ruleThickness = max(38, CGFloat(String(lineStarts.count).count) * 8 + 18)
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let text = clientView as? NSTextView, let layout = text.layoutManager, let container = text.textContainer else { return }
        let visible = text.visibleRect.offsetBy(dx: -text.textContainerOrigin.x, dy: -text.textContainerOrigin.y)
        layout.ensureLayout(forBoundingRect: visible, in: container)
        let visibleGlyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let firstCharacter = layout.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil).location
        var lower = 0, upper = lineStarts.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if lineStarts[middle] <= firstCharacter { lower = middle + 1 } else { upper = middle }
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        let count = (text.string as NSString).length
        for index in max(0, lower - 1)..<lineStarts.count {
            let start = lineStarts[index]
            let line: NSRect
            if start < count { line = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: start), effectiveRange: nil) }
            else { line = layout.extraLineFragmentRect }
            let height = max(24, line.height)
            let point = convert(NSPoint(x: 0, y: text.textContainerOrigin.y + line.minY), from: text)
            guard point.y + height >= rect.minY else { continue }
            if point.y > rect.maxY { break }
            let label = String(index + 1) as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 9, y: point.y + (height - size.height) / 2), withAttributes: attributes)
        }
    }
}
