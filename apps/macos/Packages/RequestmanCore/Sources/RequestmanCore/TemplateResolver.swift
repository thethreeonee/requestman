import Foundation

public enum TemplateResolver {
    public static func resolve(_ template: String, environment: [String: String], id: UUID, date: Date) throws -> String {
        try resolve(template, environment: environment, context: WorkflowTemplateContext(id: id, date: date))
    }

    public static func resolve(_ template: String, environment: [String: String], context: WorkflowTemplateContext,
                               responseStatus: Int? = nil, regexCaptures: [String]? = nil) throws -> String {
        // Single pass: values cannot inject a second template expansion.
        var output = ""
        var remaining = template[...]
        while let start = remaining.range(of: "{{") {
            output += try resolveCaptures(remaining[..<start.lowerBound], captures: regexCaptures)
            guard let end = remaining[start.upperBound...].range(of: "}}") else {
                throw WorkflowError.invalid("动态值缺少 }}")
            }
            let key = remaining[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("$env.") || key.hasPrefix("env.") {
                let prefix = key.hasPrefix("$env.") ? "$env." : "env."
                guard let value = environment[String(key.dropFirst(prefix.count))] else {
                    throw WorkflowError.invalid("未找到变量：\(key)")
                }
                output += value
            } else {
                output += try context.value(for: key, responseStatus: responseStatus)
            }
            remaining = remaining[end.upperBound...]
        }
        output += try resolveCaptures(remaining, captures: regexCaptures)
        return output
    }

    /// Only parse original template text; inserted environment and capture values stay literal.
    private static func resolveCaptures(_ text: Substring, captures: [String]?) throws -> String {
        guard let captures else { return String(text) }
        var output = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            index = text.index(after: index)
            guard character == "$", index < text.endIndex else { output.append(character); continue }
            if text[index] == "$" {
                output.append("$"); index = text.index(after: index); continue
            }
            let start = index
            while index < text.endIndex, text[index].isASCII, text[index].isNumber {
                index = text.index(after: index)
            }
            guard start != index else { output.append("$"); continue }
            let reference = text[start..<index]
            guard let number = Int(reference), captures.indices.contains(number) else {
                throw WorkflowError.invalid("未找到正则捕获组：$\(reference)，请检查匹配条件；字面 $ 请写为 $$")
            }
            output += captures[number]
        }
        return output
    }
}
