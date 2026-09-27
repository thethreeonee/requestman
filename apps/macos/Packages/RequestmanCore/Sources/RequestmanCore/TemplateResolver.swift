import Foundation

public enum TemplateResolver {
    public static func resolve(_ template: String, environment: [String: String], id: UUID, date: Date) throws -> String {
        try resolve(template, environment: environment, context: WorkflowTemplateContext(id: id, date: date))
    }

    public static func resolve(_ template: String, environment: [String: String], context: WorkflowTemplateContext,
                               responseStatus: Int? = nil) throws -> String {
        // Single pass: values cannot inject a second template expansion.
        var output = ""
        var remaining = template[...]
        while let start = remaining.range(of: "{{") {
            output += remaining[..<start.lowerBound]
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
        output += remaining
        return output
    }

}
