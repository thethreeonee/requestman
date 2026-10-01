import Foundation

public enum RequestLogContentField: String, CaseIterable, Codable, Sendable {
    case time, status, url, method, ruleGroup, rule, rules, device, duration
    case header, queryParameter, host, path, detail

    public var title: String {
        switch self {
        case .time: "时间"
        case .status: "状态码"
        case .url: "URL"
        case .method: "请求方法"
        case .ruleGroup: "规则组"
        case .rule: "规则"
        case .rules: "规则组与规则"
        case .device: "设备来源"
        case .duration: "耗时"
        case .header: "Header"
        case .queryParameter: "查询参数"
        case .host: "主机"
        case .path: "路径"
        case .detail: "重放与错误信息"
        }
    }

    public var stages: [RequestLogExtraColumn.Stage] {
        switch self {
        case .header: RequestLogExtraColumn.Stage.allCases
        case .status: [.originalResponse, .returnedResponse]
        case .url, .method, .queryParameter, .host, .path: [.originalRequest, .sentRequest]
        default: []
        }
    }

    public var needsName: Bool { self == .header || self == .queryParameter }

    var extraField: RequestLogExtraColumn.Field? { RequestLogExtraColumn.Field(rawValue: rawValue) }
}

public enum RequestLogHorizontalAlignment: String, CaseIterable, Codable, Sendable {
    case left, center, right
}

public enum RequestLogVerticalAlignment: String, CaseIterable, Codable, Sendable {
    case top, center, bottom
}

public enum RequestLogEmptyBehavior: String, CaseIterable, Codable, Sendable {
    case hide, customText
}

public struct RequestLogLayoutContent: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var field: RequestLogContentField
    public var stage: RequestLogExtraColumn.Stage
    public var name: String
    public var horizontalAlignment: RequestLogHorizontalAlignment
    public var verticalAlignment: RequestLogVerticalAlignment
    public var emptyBehavior: RequestLogEmptyBehavior
    public var emptyText: String
    public var appearance: RequestLogContentAppearance

    public init(id: UUID = UUID(), field: RequestLogContentField = .url,
                stage: RequestLogExtraColumn.Stage = .originalRequest, name: String = "",
                horizontalAlignment: RequestLogHorizontalAlignment = .left,
                verticalAlignment: RequestLogVerticalAlignment = .center,
                emptyBehavior: RequestLogEmptyBehavior = .hide, emptyText: String = "",
                appearance: RequestLogContentAppearance = .init()) {
        self.id = id; self.field = field; self.stage = stage; self.name = name
        self.horizontalAlignment = horizontalAlignment; self.verticalAlignment = verticalAlignment
        self.emptyBehavior = emptyBehavior; self.emptyText = emptyText
        self.appearance = appearance
    }

    private enum CodingKeys: String, CodingKey {
        case id, field, stage, name, horizontalAlignment, verticalAlignment, emptyBehavior, emptyText, appearance
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        field = try values.decode(RequestLogContentField.self, forKey: .field)
        stage = try values.decode(RequestLogExtraColumn.Stage.self, forKey: .stage)
        name = try values.decode(String.self, forKey: .name)
        horizontalAlignment = try values.decode(RequestLogHorizontalAlignment.self, forKey: .horizontalAlignment)
        verticalAlignment = try values.decode(RequestLogVerticalAlignment.self, forKey: .verticalAlignment)
        emptyBehavior = try values.decode(RequestLogEmptyBehavior.self, forKey: .emptyBehavior)
        emptyText = try values.decode(String.self, forKey: .emptyText)
        appearance = try values.decodeIfPresent(RequestLogContentAppearance.self, forKey: .appearance) ?? .init()
    }

    public var displayTitle: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return field.needsName && !trimmedName.isEmpty ? trimmedName : field.title
    }

    public var validationError: String? {
        guard let extraField = field.extraField else { return nil }
        return RequestLogExtraColumn(field: extraField, stage: stage, name: name).validationError
    }
}

public struct RequestLogLayoutLine: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var contents: [RequestLogLayoutContent]

    public init(id: UUID = UUID(), contents: [RequestLogLayoutContent] = []) {
        self.id = id; self.contents = contents
    }
}

public struct RequestLogLayoutColumn: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var title: String
    public var lines: [RequestLogLayoutLine]

    public init(id: String = "layout." + UUID().uuidString, title: String = "新列",
                lines: [RequestLogLayoutLine] = []) {
        self.id = id; self.title = title; self.lines = lines
    }
}

public struct RequestLogRenderedContent: Equatable, Sendable {
    public let configuration: RequestLogLayoutContent
    /// Captured text remains complete, including repeated values separated by newlines.
    public let text: String
    public let valueCount: Int

    public var displayText: String {
        let repeated = configuration.field == .header || configuration.field == .queryParameter
        let multiline = repeated && configuration.appearance.repeatedValues == .multipleLines
            || configuration.field == .rules && configuration.appearance.ruleSeparator == .newLine
        let visible = multiline ? text : text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).joined(separator: " · ")
        return repeated && configuration.appearance.showsValueCount && valueCount > 0
            ? visible + " (\(valueCount)项)" : visible
    }

    public init(configuration: RequestLogLayoutContent, text: String, valueCount: Int? = nil) {
        self.configuration = configuration; self.text = text
        self.valueCount = valueCount ?? (text.isEmpty ? 0 : text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count)
    }
}

public struct RequestLogRenderedLine: Equatable, Sendable {
    public let id: UUID
    public let contents: [RequestLogRenderedContent]
    public var displayLineCount: Int { contents.map { $0.displayText.reduce(1) { $1.isNewline ? $0 + 1 : $0 } }.max() ?? 1 }

    public init(id: UUID, contents: [RequestLogRenderedContent]) {
        self.id = id; self.contents = contents
    }
}

extension RequestLogDisplayOptions {
    /// Legacy choices are projected without changing their saved enabled state or physical IDs.
    var migratedLayoutColumns: [RequestLogLayoutColumn] {
        orderedColumnIDs.compactMap { id in
            guard isColumnVisible(id, allowLAN: true) else { return nil }
            var lines: [[RequestLogLayoutContent]] = []
            func content(_ field: RequestLogContentField, stage: RequestLogExtraColumn.Stage = .originalRequest,
                         alignment: RequestLogHorizontalAlignment = .left) -> RequestLogLayoutContent {
                .init(id: Self.layoutIdentity(id + "." + field.rawValue), field: field,
                      stage: stage, horizontalAlignment: alignment)
            }
            switch id {
            case "time": lines = [[content(.time)]]
            case "request":
                var first: [RequestLogLayoutContent] = []
                if columns.contains(.status) { first.append(content(.status, stage: .returnedResponse)) }
                if showsMethod { first.append(content(.method)) }
                if columns.contains(.request) { first.append(content(.url)) }
                lines = [first, [content(.detail)]]
            case "rules": lines = [[content(.ruleGroup)], [content(.rule)]]
            case "device": lines = [[content(.device, alignment: .center)]]
            case "duration": lines = [[content(.duration, alignment: .right)]]
            default:
                if let extra = extraColumns.first(where: { $0.identifier == id }) {
                    lines = [[Self.layoutContent(for: extra)]]
                }
            }
            let merged = mergedFields(in: id).map(Self.layoutContent(for:))
            if !merged.isEmpty {
                if lines.count > 1 { lines[1].append(contentsOf: merged) }
                else { lines.append(merged) }
            }
            return .init(id: id, title: title(forColumnID: id), lines: lines.enumerated().map { index, contents in
                .init(id: Self.layoutIdentity(id + ".line." + String(index)), contents: contents)
            })
        }
    }

    private static func layoutContent(for extra: RequestLogExtraColumn) -> RequestLogLayoutContent {
        .init(id: extra.id, field: RequestLogContentField(rawValue: extra.field.rawValue)!,
              stage: extra.stage, name: extra.name)
    }

    /// Unlike Swift's randomized Hasher, this makes repeated legacy projections keep stable IDs.
    private static func layoutIdentity(_ value: String) -> UUID {
        func hash(_ salt: String) -> UInt64 {
            (salt + value).utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        }
        let first = hash("requestman.layout.0."), second = hash("requestman.layout.1.")
        var bytes = (0..<8).map { UInt8(truncatingIfNeeded: first >> ($0 * 8)) }
        bytes += (0..<8).map { UInt8(truncatingIfNeeded: second >> ($0 * 8)) }
        bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
