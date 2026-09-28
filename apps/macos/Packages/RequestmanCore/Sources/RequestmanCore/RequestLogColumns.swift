import Foundation

public enum RequestLogStandardColumn: String, CaseIterable, Sendable {
    case time, status, request, rules, device, duration
    public var title: String {
        switch self {
        case .time: "时间"
        case .status: "状态码"
        case .request: "请求"
        case .rules: "命中的规则"
        case .device: "设备来源"
        case .duration: "耗时"
        }
    }
}

public struct RequestLogExtraColumn: Identifiable, Equatable, Codable, Sendable {
    public enum Field: String, CaseIterable, Codable, Sendable {
        case header, queryParameter, url, host, path, method, status
        public var title: String {
            switch self {
            case .header: "Header"
            case .queryParameter: "查询参数"
            case .url: "URL"
            case .host: "主机"
            case .path: "路径"
            case .method: "请求方法"
            case .status: "状态码"
            }
        }
        public var needsName: Bool { self == .header || self == .queryParameter }
        public var stages: [Stage] {
            switch self {
            case .header: Stage.allCases
            case .status: [.originalResponse, .returnedResponse]
            default: [.originalRequest, .sentRequest]
            }
        }
    }
    public enum Stage: String, CaseIterable, Codable, Sendable {
        case originalRequest, sentRequest, originalResponse, returnedResponse
        public var title: String {
            switch self {
            case .originalRequest: "原始请求"
            case .sentRequest: "发出的请求"
            case .originalResponse: "原始响应"
            case .returnedResponse: "返回的响应"
            }
        }
    }

    public static let legacyHeaderID = UUID(uuidString: "E2A14055-729D-44DF-8881-B3A31A2F87A5")!
    public var id: UUID
    public var field: Field
    public var stage: Stage
    public var name: String
    public var title: String
    public var isEnabled: Bool
    public var identifier: String { "extra." + id.uuidString }
    public var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var displayTitle: String {
        let custom = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? (field.needsName ? trimmedName : field.title) : custom
    }
    public var summary: String { stage.title + " · " + field.title + (field.needsName ? " · " + trimmedName : "") }
    public var validationError: String? {
        guard field.stages.contains(stage) else { return "请选择此字段支持的阶段" }
        if field.needsName && trimmedName.isEmpty { return "请输入" + (field == .header ? " Header 名称" : "查询参数名") }
        if field == .header {
            let allowed = "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
            if !trimmedName.utf8.allSatisfy({ allowed.utf8.contains($0) }) { return "请输入有效的 Header 名称" }
        }
        return nil
    }

    public init(id: UUID = UUID(), field: Field = .header, stage: Stage = .originalRequest,
                name: String = "", title: String = "", isEnabled: Bool = true) {
        self.id = id; self.field = field; self.stage = stage
        self.name = name; self.title = title; self.isEnabled = isEnabled
    }

    /// nil denotes an unavailable field; an empty string remains a captured empty value.
    public func value(in record: CaptureRecord) -> String? {
        guard validationError == nil else { return nil }
        switch field {
        case .header:
            let fields: [HTTPField]
            switch stage {
            case .originalRequest: fields = record.requestHeaders
            case .sentRequest: fields = record.sentHeaders
            case .originalResponse: fields = record.receivedHeaders
            case .returnedResponse: fields = record.responseHeaders
            }
            let values = fields.filter { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }.map(\.value)
            return values.isEmpty ? nil : values.joined(separator: "\n")
        case .status:
            return (stage == .originalResponse ? record.originalStatus : record.status).map(String.init)
        case .method:
            guard stage == .originalRequest || record.hasSentRequestHeaders else { return nil }
            return stage == .originalRequest ? record.method : record.sentMethod
        case .url, .host, .path, .queryParameter:
            guard stage == .originalRequest || record.hasSentRequestHeaders else { return nil }
            // A truncated URL cannot establish complete query values or even a complete path.
            guard !(stage == .originalRequest ? record.urlWasTruncated : record.finalURLWasTruncated) else { return nil }
            let url = stage == .originalRequest ? record.url : record.finalURL
            if field == .url { return url.isEmpty ? nil : url }
            guard let address = URLComponents(string: url), address.scheme != nil, address.host != nil else { return nil }
            switch field {
            case .host: return address.host
            case .path: return address.percentEncodedPath.isEmpty ? "/" : address.percentEncodedPath
            case .queryParameter:
                let values = (address.queryItems ?? []).filter { $0.name == trimmedName }.map { $0.value ?? "" }
                return values.isEmpty ? nil : values.joined(separator: "\n")
            default: return nil
            }
        }
    }
}

public struct RequestLogDisplayOptions: Equatable, Sendable {
    public static let defaultsKey = "requestLog.displayOptions.v1"
    public var columns = Set(RequestLogStandardColumn.allCases)
    public var extraColumns: [RequestLogExtraColumn] = []
    public var columnOrder: [String] = []
    public init() {}

    public func isVisible(_ column: RequestLogStandardColumn, allowLAN: Bool) -> Bool {
        columns.contains(column) && (column != .device || allowLAN)
    }

    /// Stable identities keep ordering independent of titles, visibility and widths.
    public var orderedColumnIDs: [String] {
        let extraIDs = extraColumns.map(\.identifier)
        let standardIDs = RequestLogStandardColumn.allCases.map(\.rawValue)
        var fallback = standardIDs
        fallback.insert(contentsOf: extraIDs, at: 3)
        let valid = Set(fallback)
        var seen = Set<String>()
        var result = columnOrder.filter { valid.contains($0) && seen.insert($0).inserted }
        if result.isEmpty { return fallback }
        for id in standardIDs where !seen.contains(id) { result.append(id); seen.insert(id) }
        for id in extraIDs where !seen.contains(id) {
            let anchor = result.lastIndex { extraIDs.contains($0) } ?? result.firstIndex(of: "request")
            result.insert(id, at: anchor.map { $0 + 1 } ?? result.endIndex)
            seen.insert(id)
        }
        return result
    }

    public init(preferences: [String: Any]) {
        self.init()
        if let names = preferences["columns"] as? [String] {
            columns = Set(names.compactMap(RequestLogStandardColumn.init(rawValue:)))
            if columns.subtracting([.device]).isEmpty { columns.insert(.request) }
        }
        if let saved = preferences["extraColumns"] as? [[String: Any]] {
            var seen = Set<UUID>()
            extraColumns = saved.compactMap { item in
                guard JSONSerialization.isValidJSONObject(item),
                      let data = try? JSONSerialization.data(withJSONObject: item),
                      let column = try? JSONDecoder().decode(RequestLogExtraColumn.self, from: data),
                      seen.insert(column.id).inserted else { return nil }
                return column
            }
        } else if let name = preferences["headerName"] as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            extraColumns = [.init(id: RequestLogExtraColumn.legacyHeaderID,
                                  stage: (preferences["headerSource"] as? String).flatMap(RequestLogExtraColumn.Stage.init(rawValue:)) ?? .originalRequest,
                                  name: name, isEnabled: preferences["headerEnabled"] as? Bool ?? false)]
        }
        columnOrder = preferences["columnOrder"] as? [String] ?? []
        columnOrder = orderedColumnIDs
    }

    public var preferences: [String: Any] {
        let extra = extraColumns.compactMap { column -> [String: Any]? in
            guard let data = try? JSONEncoder().encode(column) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        return ["columns": columns.map(\.rawValue).sorted(), "extraColumns": extra, "columnOrder": orderedColumnIDs]
    }
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(preferences: defaults.dictionary(forKey: defaultsKey) ?? [:])
    }
    public func save(to defaults: UserDefaults = .standard) { defaults.set(preferences, forKey: Self.defaultsKey) }
}
