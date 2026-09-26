import AppKit
import RequestmanEditor

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

extension CodeEditorView {
    @discardableResult func formatJSON() -> Bool {
        guard textView.isEditable, !textView.hasMarkedText(), let formatted = BodyJSONPresentation.formatted(string) else { return false }
        replaceText(with: formatted)
        return true
    }
}
