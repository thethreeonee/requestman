import CoreFoundation
import Foundation
import RequestmanCore

enum RequestDetailTab: String, CaseIterable, Identifiable, Sendable {
    case requestHeaders, requestBody, responseHeaders, responseBody
    var id: Self { self }
    var title: String {
        switch self {
        case .requestHeaders: "请求头"
        case .requestBody: "请求体"
        case .responseHeaders: "响应头"
        case .responseBody: "响应体"
        }
    }
    var isRequest: Bool { self == .requestHeaders || self == .requestBody }
    var isBody: Bool { self == .requestBody || self == .responseBody }
}

enum InspectionFormat: String, CaseIterable, Sendable {
    case tree, source

    var title: String {
        switch self {
        case .tree: "树形"
        case .source: "源码"
        }
    }
}

/// Pure presentation data. Parsing and comparison can run away from the main actor.
enum RequestInspectionData {

    static func headers(
        original: [HTTPField],
        final: [HTTPField],
        originalInfo: CaptureHeadersInfo,
        finalInfo: CaptureHeadersInfo,
        version: InspectionVersion
    ) -> [RequestDataNode] {
        let old = indexedHeaders(original)
        let new = indexedHeaders(final)
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0.field) })
        let newByID = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0.field) })
        let originalUnavailableNames = Set(originalInfo.truncatedNames.map { $0.lowercased() })
        let finalUnavailableNames = Set(finalInfo.truncatedNames.map { $0.lowercased() })
        let unavailableNames = originalUnavailableNames.union(finalUnavailableNames)
        let order: [IndexedHeader]
        switch version {
        case .original: order = old
        case .final: order = new
        case .difference: order = old + new.filter { oldByID[$0.id] == nil }
        }
        return order.compactMap { item in
            let before = oldByID[item.id]
            let after = newByID[item.id]
            let displayed = version == .original ? before : (after ?? before)
            guard let displayed else { return nil }
            let displayedUnavailableNames = version == .original || after == nil ? originalUnavailableNames : finalUnavailableNames
            var change = RequestDataChange.unchanged
            if !unavailableNames.contains(item.field.name.lowercased()) {
                switch (before, after) {
                case let (.some(before), .some(after)):
                    if before.value != after.value { change = .modified }
                case (.none, .some):
                    if !originalInfo.isTruncated { change = .added }
                case (.some, .none):
                    if !finalInfo.isTruncated { change = .removed }
                case (.none, .none): break
                }
            }
            return RequestDataNode(
                id: item.id, name: displayed.name, value: displayed.value,
                copyValue: displayed.value, change: change,
                originalValue: version == .difference && change == .modified ? before?.value : nil,
                jsonStringValue: displayedUnavailableNames.contains(displayed.name.lowercased()) ? nil : displayed.value
            )
        }
    }

    /// A missing root is unavailable capture data, not a JSON null or a removed body.
    /// Missing keys within two available roots, however, are genuine additions/removals.
    static func json(original: Data?, final: Data?, version: InspectionVersion) throws -> [RequestDataNode] {
        let before: JSONValue?
        let after: JSONValue?
        switch version {
        case .original:
            before = try original.map(parseJSON)
            after = try comparisonJSON(final)
        case .final:
            before = try comparisonJSON(original)
            after = try final.map(parseJSON)
        case .difference:
            if let final {
                before = try comparisonJSON(original)
                after = try parseJSON(final)
            } else {
                before = try original.map(parseJSON)
                after = nil
            }
        }
        guard let root = makeJSONNode(
            name: "$", path: "$", original: before, final: after,
            version: version, canCompare: before != nil && after != nil
        ) else { return [] }
        return [root]
    }

    /// Parse the decoded string value, never the quoted or shortened cell label.
    /// Discovery is lazy in the native row; reuse the body parser and cancellation.
    static func stringJSONPreview(_ source: String) -> [RequestDataNode]? {
        guard let value = try? parseJSON(Data(source.utf8)),
              let root = makeJSONNode(name: "$", path: "$", original: nil, final: value,
                                      version: .final, canCompare: false) else { return nil }
        return [root]
    }

    /// Searches visible data, preserving the path to matches. A matching container
    /// includes its descendants; change-only filtering still applies to that subtree.
    static func filtering(_ nodes: [RequestDataNode], query: String, onlyChanges: Bool) -> [RequestDataNode] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func filter(_ node: RequestDataNode, ancestorMatches: Bool) -> RequestDataNode? {
            let matches = ancestorMatches || search.isEmpty ||
                node.name.localizedCaseInsensitiveContains(search) ||
                node.value.localizedCaseInsensitiveContains(search) ||
                (node.originalValue?.localizedCaseInsensitiveContains(search) ?? false)
            let children = node.children.compactMap { filter($0, ancestorMatches: matches) }
            let passesSearch = matches || !children.isEmpty
            let passesChanges = !onlyChanges || node.change != .unchanged || !children.isEmpty
            guard passesSearch && passesChanges else { return nil }
            return RequestDataNode(
                id: node.id, name: node.name, value: node.value, typeName: node.typeName,
                copyValue: node.copyValue, children: children, change: node.change,
                valueKind: node.valueKind, originalValue: node.originalValue,
                highlightsChange: node.highlightsChange, jsonStringValue: node.jsonStringValue
            )
        }
        return nodes.compactMap { filter($0, ancestorMatches: false) }
    }

    private struct IndexedHeader {
        let id: String
        let field: HTTPField
    }

    /// Repeated names are paired by occurrence, without flattening Set-Cookie etc.
    private static func indexedHeaders(_ fields: [HTTPField]) -> [IndexedHeader] {
        var counts: [String: Int] = [:]
        return fields.map { field in
            let name = field.name.lowercased()
            let index = counts[name, default: 0]
            counts[name] = index + 1
            return IndexedHeader(id: "header:\(name):\(index)", field: field)
        }
    }

    private indirect enum JSONValue: Equatable {
        case object([String: JSONValue])
        case array([JSONValue])
        case string(String)
        case number(String)
        case boolean(Bool)
        case null

        var stringValue: String? {
            if case let .string(value) = self { return value }
            return nil
        }

        var serialized: String {
            switch self {
            case let .object(fields):
                "{" + fields.keys.sorted().map { "\(quoted($0)):\(fields[$0]!.serialized)" }.joined(separator: ",") + "}"
            case let .array(items): "[" + items.map(\.serialized).joined(separator: ",") + "]"
            case let .string(value): quoted(value)
            case let .number(value): value
            case let .boolean(value): value ? "true" : "false"
            case .null: "null"
            }
        }

        var summary: String {
            switch self {
            case let .object(fields): "{ \(fields.count) 个字段 }"
            case let .array(items): "[ \(items.count) 项 ]"
            default: serialized
            }
        }

        var typeName: String {
            switch self {
            case .object: "Object"
            case .array: "Array"
            case .string: "String"
            case .number: "Number"
            case .boolean: "Boolean"
            case .null: "Null"
            }
        }

        var valueKind: RequestDataValueKind {
            switch self {
            case .object, .array: .plain
            case .string: .string
            case .number: .number
            case .boolean: .boolean
            case .null: .null
            }
        }
    }

    private static func quoted(_ value: String) -> String {
        // A Swift String always has a valid JSON string representation.
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func parseJSON(_ data: Data) throws -> JSONValue {
        try Task.checkCancellation()
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        func convert(_ object: Any) throws -> JSONValue {
            try Task.checkCancellation()
            if let fields = object as? [String: Any] {
                return .object(try fields.mapValues { try convert($0) })
            }
            if let items = object as? [Any] {
                return .array(try items.map { try convert($0) })
            }
            if let value = object as? String { return .string(value) }
            if let value = object as? NSNumber {
                if CFGetTypeID(value) == CFBooleanGetTypeID() { return .boolean(value.boolValue) }
                let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
                return .number(String(decoding: data, as: UTF8.self))
            }
            return .null
        }
        return try convert(object)
    }

    /// A different body representation cannot invalidate the selected JSON view.
    private static func comparisonJSON(_ data: Data?) throws -> JSONValue? {
        do { return try data.map(parseJSON) }
        catch is CancellationError { throw CancellationError() }
        catch { return nil }
    }

    private static func makeJSONNode(
        name: String, path: String, original: JSONValue?, final: JSONValue?,
        version: InspectionVersion, canCompare: Bool
    ) -> RequestDataNode? {
        let displayed: JSONValue?
        switch version {
        case .original: displayed = original
        case .final: displayed = final
        case .difference: displayed = final ?? original
        }
        guard let displayed else { return nil }
        let change: RequestDataChange
        if !canCompare { change = .unchanged }
        else if original == nil { change = .added }
        else if final == nil { change = .removed }
        else { change = original == final ? .unchanged : .modified }

        var children: [RequestDataNode] = []
        switch displayed {
        case .object:
            let old: [String: JSONValue]?
            let new: [String: JSONValue]?
            if case let .object(fields)? = original { old = fields } else { old = nil }
            if case let .object(fields)? = final { new = fields } else { new = nil }
            let keys: [String]
            switch version {
            case .original: keys = Array(old?.keys ?? Dictionary<String, JSONValue>().keys)
            case .final: keys = Array(new?.keys ?? Dictionary<String, JSONValue>().keys)
            case .difference: keys = Array(Set(old?.keys ?? Dictionary<String, JSONValue>().keys).union(new?.keys ?? Dictionary<String, JSONValue>().keys))
            }
            let childrenComparable = canCompare && (original == nil || old != nil) && (final == nil || new != nil)
            children = keys.sorted().compactMap { key in
                makeJSONNode(
                    name: key, path: path + "[\(quoted(key))]", original: old?[key], final: new?[key],
                    version: version, canCompare: childrenComparable
                )
            }
        case .array:
            let old: [JSONValue]?
            let new: [JSONValue]?
            if case let .array(items)? = original { old = items } else { old = nil }
            if case let .array(items)? = final { new = items } else { new = nil }
            let count: Int
            switch version {
            case .original: count = old?.count ?? 0
            case .final: count = new?.count ?? 0
            case .difference: count = max(old?.count ?? 0, new?.count ?? 0)
            }
            let childrenComparable = canCompare && (original == nil || old != nil) && (final == nil || new != nil)
            children = (0..<count).compactMap { index in
                makeJSONNode(
                    name: "[\(index)]", path: path + "[\(index)]",
                    original: old.flatMap { index < $0.count ? $0[index] : nil },
                    final: new.flatMap { index < $0.count ? $0[index] : nil },
                    version: version, canCompare: childrenComparable
                )
            }
        default: break
        }
        return RequestDataNode(
            id: path, name: name, value: displayed.summary, typeName: displayed.typeName,
            copyValue: displayed.serialized, children: children, change: change,
            valueKind: displayed.valueKind,
            originalValue: version == .difference && change == .modified && original?.summary != displayed.summary
                ? original?.summary : nil,
            highlightsChange: highlightsJSONChange(change, original: original, final: final),
            jsonStringValue: displayed.stringValue
        )
    }

    /// Parent change propagates for filtering, but a descendant edit alone does not
    /// tint every container along its path. Changed type/count still has a visual cue.
    private static func highlightsJSONChange(
        _ change: RequestDataChange, original: JSONValue?, final: JSONValue?
    ) -> Bool {
        guard change != .unchanged else { return false }
        guard change == .modified else { return true }
        switch (original, final) {
        case let (.object(old)?, .object(new)?): return old.count != new.count
        case let (.array(old)?, .array(new)?): return old.count != new.count
        default: return true
        }
    }
}
