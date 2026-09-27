import Foundation

public enum JSONEditOperation: String, Codable, CaseIterable, Sendable {
    case set, modify, remove
    public var title: String {
        switch self {
        case .set: "添加或覆盖"
        case .modify: "修改"
        case .remove: "删除"
        }
    }
}

public struct JSONEditEntry: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var operation: JSONEditOperation
    public var path: String
    /// A JSON value, including quotes for strings. Templates expand before parsing.
    public var value: String
    public init(operation: JSONEditOperation = .set, path: String = "", value: String = "\"\"") {
        self.operation = operation; self.path = path; self.value = value
    }
}

struct JSONBodyProcessor: StepProcessor {
    func requirements(for step: ModificationStep) -> StepExecutionRequirements {
        step.jsonEntries.isEmpty ? .init() : .init(input: .completeBody, background: true)
    }

    func process(_ step: ModificationStep, draft: inout HTTPMessageDraft, context: ModificationExecutionContext) throws {
        guard !step.jsonEntries.isEmpty else { return }
        let text: String?
        if let bytes = draft.replacementBodyData {
            guard !draft.headers.contains(where: { $0.name.lowercased() == "content-encoding" && $0.value.lowercased() != "identity" }) else {
                throw WorkflowError.invalid("修改 JSON 前请先将压缩 Body 替换为 JSON 文本")
            }
            text = String(data: bytes, encoding: .utf8)
        } else if let current = draft.replacementBody ?? draft.bodyText { text = current }
        else if !draft.headers.contains(where: { $0.name.lowercased() == "content-encoding" && $0.value.lowercased() != "identity" }) {
            text = draft.bodyData.flatMap { String(data: $0, encoding: .utf8) }
        } else { text = nil }
        guard let text else { throw WorkflowError.invalid("Body 无法解码为 UTF-8 JSON") }
        var parser = JSONEditParser(text)
        var root = try parser.parse()
        let original = root.serialized
        for (index, entry) in step.jsonEntries.enumerated() {
            try context.control.check()
            do {
                let path = try JSONEditPath.parse(context.resolve(entry.path, step: step))
                try root.edit(path[...], operation: entry.operation) {
                    var parser = JSONEditParser(try context.resolve(entry.value, step: step))
                    return try parser.parse()
                }
            } catch {
                throw WorkflowError.invalid("第 \(index + 1) 条 JSON 修改：\(error.localizedDescription)")
            }
        }
        let result = root.serialized
        guard result != original else { return }
        draft.replacementBody = result
        draft.replacementBodyData = nil
        HTTPMessageValidation.clearBodyEncoding(&draft)
    }
}

/// Keep number tokens, string escapes and object order intact outside edited values.
private indirect enum JSONEditValue {
    case object([(String, String, JSONEditValue)])
    case array([JSONEditValue])
    case scalar(String)

    var serialized: String {
        switch self {
        case .object(let fields): "{" + fields.map { $0.1 + ":" + $0.2.serialized }.joined(separator: ",") + "}"
        case .array(let values): "[" + values.map(\.serialized).joined(separator: ",") + "]"
        case .scalar(let value): value
        }
    }

    mutating func edit(_ path: ArraySlice<JSONEditPath>, operation: JSONEditOperation, value: () throws -> JSONEditValue) throws {
        guard let part = path.first else { throw WorkflowError.invalid("路径不能为空") }
        let remaining = path.dropFirst()
        switch (self, part) {
        case (.object(var fields), .key(let key)):
            let matches = fields.indices.filter { fields[$0].0 == key }
            guard matches.count <= 1 else { throw WorkflowError.invalid("路径命中重复的对象键") }
            if let index = matches.first {
                if !remaining.isEmpty { try fields[index].2.edit(remaining, operation: operation, value: value) }
                else if operation == .remove { fields.remove(at: index) }
                else { fields[index].2 = try value() }
            } else if operation == .set {
                guard remaining.isEmpty else { throw WorkflowError.invalid("父路径不存在，请先添加父对象") }
                let keyData = try JSONEncoder().encode(key)
                fields.append((key, String(decoding: keyData, as: UTF8.self), try value()))
            }
            self = .object(fields)
        case (.array(var values), .index(let index)):
            if values.indices.contains(index) {
                if !remaining.isEmpty { try values[index].edit(remaining, operation: operation, value: value) }
                else if operation == .remove { values.remove(at: index) }
                else { values[index] = try value() }
            } else if operation == .set {
                guard index == values.count, remaining.isEmpty else { throw WorkflowError.invalid("数组下标越界；仅允许在末尾追加") }
                values.append(try value())
            }
            self = .array(values)
        default: throw WorkflowError.invalid("路径与 JSON 类型不匹配")
        }
    }
}

private enum JSONEditPath {
    case key(String), index(Int)
    static func parse(_ text: String) throws -> [Self] {
        let chars = Array(text)
        var position = 0, result: [Self] = []
        func invalid() -> WorkflowError { .invalid("路径格式无效，请使用 data.name、items[0] 或 [\"特殊键名\"]") }
        func key() throws {
            let start = position
            while position < chars.count, chars[position] != ".", chars[position] != "[" {
                guard chars[position] != "]", !chars[position].isWhitespace else { throw invalid() }
                position += 1
            }
            guard start < position else { throw invalid() }
            result.append(.key(String(chars[start..<position])))
        }
        if chars.first != "[" { try key() }
        while position < chars.count {
            if chars[position] == "." { position += 1; try key() }
            else if chars[position] == "[" {
                position += 1
                let start = position
                if position < chars.count, chars[position] == "\"" {
                    position += 1
                    var escaped = false
                    while position < chars.count {
                        let char = chars[position]; position += 1
                        if escaped { escaped = false }
                        else if char == "\\" { escaped = true }
                        else if char == "\"" { break }
                    }
                    guard let key = try? JSONDecoder().decode(String.self, from: Data(String(chars[start..<position]).utf8)) else { throw invalid() }
                    result.append(.key(key))
                } else {
                    while position < chars.count, chars[position].isASCII, chars[position].isNumber { position += 1 }
                    guard start < position, let index = Int(String(chars[start..<position])), index >= 0 else { throw invalid() }
                    result.append(.index(index))
                }
                guard position < chars.count, chars[position] == "]" else { throw invalid() }
                position += 1
            } else { throw invalid() }
        }
        guard !result.isEmpty, result.count <= 128 else { throw invalid() }
        return result
    }
}

private struct JSONEditParser {
    private let bytes: [UInt8]
    private var offset = 0
    init(_ text: String) { bytes = Array(text.utf8) }
    private var invalid: WorkflowError { .invalid("内容不是有效 JSON，字符串值需加双引号") }
    mutating func parse() throws -> JSONEditValue {
        let result = try value(depth: 0)
        whitespace()
        guard offset == bytes.count else { throw invalid }
        return result
    }
    private mutating func whitespace() {
        while offset < bytes.count, [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
    }
    private mutating func consume(_ byte: UInt8) -> Bool {
        whitespace()
        guard offset < bytes.count, bytes[offset] == byte else { return false }
        offset += 1; return true
    }
    private mutating func string() throws -> (String, String) {
        whitespace()
        let start = offset
        guard offset < bytes.count, bytes[offset] == 34 else { throw invalid }
        offset += 1
        while offset < bytes.count {
            let byte = bytes[offset]; offset += 1
            if byte == 92 { guard offset < bytes.count else { throw invalid }; offset += 1 }
            else if byte == 34 {
                let data = Data(bytes[start..<offset])
                guard let decoded = try? JSONDecoder().decode(String.self, from: data) else { throw invalid }
                return (decoded, String(decoding: data, as: UTF8.self))
            }
        }
        throw invalid
    }
    private mutating func value(depth: Int) throws -> JSONEditValue {
        guard depth < 128 else { throw WorkflowError.invalid("JSON 嵌套超过 128 层") }
        whitespace()
        guard offset < bytes.count else { throw invalid }
        if consume(123) {
            var fields: [(String, String, JSONEditValue)] = []
            if consume(125) { return .object(fields) }
            repeat {
                let (key, raw) = try string()
                guard consume(58) else { throw invalid }
                fields.append((key, raw, try value(depth: depth + 1)))
            } while consume(44)
            guard consume(125) else { throw invalid }
            return .object(fields)
        }
        if consume(91) {
            var values: [JSONEditValue] = []
            if consume(93) { return .array(values) }
            repeat { values.append(try value(depth: depth + 1)) } while consume(44)
            guard consume(93) else { throw invalid }
            return .array(values)
        }
        if bytes[offset] == 34 { return .scalar(try string().1) }
        let start = offset
        while offset < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[offset]) { offset += 1 }
        let token = String(decoding: bytes[start..<offset], as: UTF8.self)
        guard ["true", "false", "null"].contains(token) || token.range(of: #"\A-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?\z"#, options: .regularExpression) != nil else { throw invalid }
        return .scalar(token)
    }
}
