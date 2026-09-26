import AppKit

/// Display-only lexical highlighting; no JavaScript is evaluated while editing.
enum JavaScriptSyntax {
    private static let keywords: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger",
        "default", "delete", "do", "else", "export", "extends", "finally", "for", "from",
        "function", "get", "if", "import", "in", "instanceof", "let", "new", "of", "return",
        "set", "static", "super", "switch", "this", "throw", "try", "typeof", "var", "void",
        "while", "with", "yield", "true", "false", "null", "undefined"
    ]
    private static let builtins: Set<String> = [
        "request", "response", "env", "JSON", "Math", "Object", "Array", "String", "Number",
        "Boolean", "Date", "RegExp", "Map", "Set", "Error", "NaN", "Infinity", "parseInt",
        "parseFloat", "isNaN", "isFinite", "encodeURIComponent", "decodeURIComponent"
    ]
    // Comments and quoted literals are matched first, so their contents cannot become keywords.
    // Incomplete literals remain highlighted while the user types their closing delimiter.
    private static let expression = try! NSRegularExpression(pattern: #"//[^\r\n]*|/\*[\s\S]*?(?:\*/|\z)|"(?:\\[\s\S]|[^"\\\r\n])*(?:"|(?=\r|\n|\z))|'(?:\\[\s\S]|[^'\\\r\n])*(?:'|(?=\r|\n|\z))|`(?:\\[\s\S]|[^`\\])*(?:`|\z)|\b0[xX][\da-fA-F_]+n?|\b0[bB][01_]+n?|\b0[oO][0-7_]+n?|(?:\b\d[\d_]*(?:\.[\d_]*)?|\.\d[\d_]*)(?:[eE][+-]?[\d_]+)?n?|[$_\p{ID_Start}][$\p{ID_Continue}\u200C\u200D]*|\S"#)

    @MainActor static func highlight(_ textView: NSTextView) {
        guard let layout = textView.layoutManager else { return }
        let text = textView.string, source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
        let items = expression.matches(in: text, range: fullRange)
        let marked = textView.markedRange()
        for (index, item) in items.enumerated() {
            guard marked.location == NSNotFound || NSIntersectionRange(marked, item.range).length == 0 else { continue }
            let token = source.substring(with: item.range)
            let color: NSColor
            if token.hasPrefix("//") || token.hasPrefix("/*") { color = .secondaryLabelColor }
            else if token.hasPrefix("\"") || token.hasPrefix("'") || token.hasPrefix("`") { color = .systemGreen }
            else if keywords.contains(token) { color = .systemPurple }
            else if token.first?.isNumber == true || (token.hasPrefix(".") && token.count > 1) { color = .systemOrange }
            else if builtins.contains(token) { color = .systemTeal }
            else if JSONSyntax.isIdentifier(token), index + 1 < items.count,
                    source.substring(with: items[index + 1].range) == "(" { color = .systemBlue }
            else { continue }
            layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: item.range)
        }
    }
}
