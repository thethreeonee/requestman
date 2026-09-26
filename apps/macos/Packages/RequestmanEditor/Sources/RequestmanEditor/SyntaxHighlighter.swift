import AppKit
import Highlighter

/// Serializes JavaScriptCore work away from the UI; only Sendable color runs cross actors.
actor SyntaxHighlighter {
    struct ColorRun: Sendable {
        let range: NSRange
        let red: Double, green: Double, blue: Double, alpha: Double
    }
    private lazy var engine = Highlighter()
    private var darkTheme: Bool?

    func highlight(_ source: String, language: String, dark: Bool) -> [ColorRun] {
        guard language != "plaintext", !source.isEmpty, let engine else { return [] }
        engine.ignoreIllegals = true
        if darkTheme != dark {
            _ = engine.setTheme(dark ? "atom-one-dark" : "atom-one-light")
            darkTheme = dark
        }
        guard let highlighted = engine.highlight(source, as: language), highlighted.string == source else { return [] }
        var colors: [ColorRun] = []
        highlighted.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: highlighted.length)) { value, range, _ in
            guard let color = (value as? NSColor)?.usingColorSpace(.sRGB) else { return }
            colors.append(ColorRun(range: range, red: color.redComponent, green: color.greenComponent,
                                   blue: color.blueComponent, alpha: color.alphaComponent))
        }
        return colors
    }
}
