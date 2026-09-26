import AppKit

/// Shared JSON tokenization and semantic colors for editors, source views and field trees.
enum JSONSyntax {
    enum Role { case key, string, number, boolean, null, punctuation, plain }

    @MainActor static func color(_ role: Role) -> NSColor {
        switch role {
        case .key: .systemBlue
        case .string: .systemGreen
        case .number: .systemOrange
        case .boolean, .null: .systemPurple
        case .punctuation: .secondaryLabelColor
        case .plain: .labelColor
        }
    }

    private static let expression = try! NSRegularExpression(pattern: #"\{\{[^{}\r\n]+\}\}|"(?:\\.|[^"\\])*"|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|[$_\p{ID_Start}][$\p{ID_Continue}\u200C\u200D]*|[{}\[\]:,]|\S"#)
    private static let identifier = try! NSRegularExpression(pattern: #"\A[$_\p{ID_Start}][$\p{ID_Continue}\u200C\u200D]*\z"#)

    static func isIdentifier(_ text: String) -> Bool {
        identifier.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    static func tokens(_ text: String) -> [(text: String, range: NSRange)] {
        let source = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: source.length)).map {
            (source.substring(with: $0.range), $0.range)
        }
    }

    @MainActor static func highlight(_ textView: NSTextView, enabled: Bool = true, templateRanges: [NSRange] = []) {
        guard let layout = textView.layoutManager else { return }
        let source = textView.string
        let fullRange = NSRange(location: 0, length: (source as NSString).length)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
        guard enabled else { return }
        let items = tokens(source)
        let marked = textView.markedRange()
        for (index, item) in items.enumerated() {
            guard marked.location == NSNotFound || NSIntersectionRange(marked, item.range).length == 0 else { continue }
            let role: Role
            if index + 1 < items.count && items[index + 1].text == ":" && isIdentifier(item.text) { role = .key }
            else if item.text.hasPrefix("\"") {
                role = index + 1 < items.count && items[index + 1].text == ":" ? .key : .string
            } else if ["true", "false", "null"].contains(item.text) { role = item.text == "null" ? .null : .boolean }
            else if item.text.first?.isNumber == true || item.text.hasPrefix("-") { role = .number }
            else if ["{", "}", "[", "]", ":", ","].contains(item.text) { role = .punctuation }
            else { continue }
            layout.addTemporaryAttribute(.foregroundColor, value: color(role), forCharacterRange: item.range)
        }
        // Template marks win over the enclosing JSON string color.
        for range in templateRanges {
            layout.addTemporaryAttribute(.foregroundColor, value: color(.key), forCharacterRange: range)
        }
    }
}
