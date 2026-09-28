import Foundation

public enum CaptureResourceType: String, CaseIterable, Sendable {
    case all = "全部", json = "JSON", document = "文档", css = "CSS", script = "JS"
    case sse = "SSE", webSocket = "WS"
    case image = "图片", font = "字体", media = "媒体", other = "其他"

    public static func classify(_ record: CaptureRecord) -> Self {
        guard record.outcome != .tunnel else { return .other }
        if record.captureProtocol == .sse { return .sse }
        if record.captureProtocol == .webSocket { return .webSocket }
        let contentType = record.responseHeaders.first { $0.name.lowercased() == "content-type" }?
            .value.lowercased().split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        if !contentType.isEmpty {
            if contentType == "application/json" || contentType.hasSuffix("+json") { return .json }
            if ["text/html", "application/xhtml+xml", "application/xml", "text/xml"].contains(contentType) { return .document }
            if contentType == "text/css" { return .css }
            if contentType.contains("javascript") || contentType.contains("ecmascript") { return .script }
            if contentType.hasPrefix("image/") { return .image }
            if contentType.hasPrefix("font/") || contentType.contains("font") { return .font }
            if contentType.hasPrefix("audio/") || contentType.hasPrefix("video/") { return .media }
            return .other
        }
        // Only use an extension when response MIME is unavailable; never infer Fetch/XHR from a proxy.
        switch URL(string: record.finalURL)?.pathExtension.lowercased() ?? "" {
        case "json": return .json
        case "html", "htm", "xhtml", "xml": return .document
        case "css": return .css
        case "js", "mjs", "cjs": return .script
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "avif": return .image
        case "woff", "woff2", "ttf", "otf", "eot": return .font
        case "mp4", "webm", "mov", "mp3", "wav", "ogg", "m4a": return .media
        default: return .other
        }
    }
}

public enum CaptureHeaderSource: String, CaseIterable, Sendable { case original = "原始请求", sent = "修改后请求" }
public enum CaptureHeaderCombination: String, CaseIterable, Sendable { case all = "满足全部条件", any = "满足任一条件" }
public enum CaptureHeaderOperator: String, CaseIterable, Sendable {
    case contains = "包含", equals = "等于", exists = "存在", absent = "不存在"
    public var needsValue: Bool { self == .contains || self == .equals }
}
public struct CaptureHeaderCondition: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var operation: CaptureHeaderOperator
    public var value: String
    public init(id: UUID = UUID(), name: String = "", operation: CaptureHeaderOperator = .contains, value: String = "") {
        self.id = id; self.name = name; self.operation = operation; self.value = value
    }
    public var normalizedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    public var isActive: Bool { !normalizedName.isEmpty && (operation != .contains || !value.isEmpty) }

    /// nil means unavailable evidence, and must remain unknown even under inversion.
    func matches(fields: [HTTPField], info: CaptureHeadersInfo) -> Bool? {
        let key = normalizedName
        let values = fields.filter { $0.name.lowercased() == key }.map(\.value)
        let nameWasTruncated = info.truncatedNames.contains(key) && key.count >= 128
        if operation == .exists || operation == .absent {
            if !values.isEmpty && !nameWasTruncated { return operation == .exists }
            if info.isTruncated || nameWasTruncated { return nil }
            return operation == .absent
        }
        guard !values.isEmpty else { return info.isTruncated ? nil : false }
        guard !info.truncatedNames.contains(key) else { return nil }
        if values.contains(where: { operation == .equals ? $0 == value : $0.contains(value) }) { return true }
        return info.isTruncated ? nil : false // A duplicate header beyond the capture limit could still match.
    }
}

/// Values within one text condition are alternatives; exclusions always take precedence.
public struct CaptureFilterTerms: Equatable, Sendable {
    public var included: [String] = []
    public var excluded: [String] = []
    public init(_ input: String) {
        for token in input.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "，" }) {
            if token.first == "-" {
                if token.count > 1 { excluded.append(String(token.dropFirst())) }
            } else { included.append(String(token)) }
        }
    }
    public var isEmpty: Bool { included.isEmpty && excluded.isEmpty }
    func matches(_ predicate: (String) -> Bool) -> Bool {
        !excluded.contains(where: predicate) && (included.isEmpty || included.contains(where: predicate))
    }
}

public enum CaptureFilterField: String, CaseIterable, Sendable {
    case url = "URL", domain = "域名", method = "请求方法", status = "状态码"
    case project = "命中规则组", workflow = "命中规则", environment = "环境", outcome = "结果"
    case active = "活动连接", header = "请求 Header"
    public var supportsMultipleValues: Bool { [.url, .domain, .method, .status].contains(self) }
    public var operations: [CaptureHeaderOperator] {
        switch self {
        case .url, .header: return self == .header ? CaptureHeaderOperator.allCases : [.contains, .equals]
        case .active: return [.exists, .absent]
        default: return [.equals]
        }
    }
}

public struct CaptureFilterCondition: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var field: CaptureFilterField
    public var operation: CaptureHeaderOperator
    public var value: String
    public var headerName: String
    public var headerSource: CaptureHeaderSource
    public init(id: UUID = UUID(), field: CaptureFilterField = .url,
                operation: CaptureHeaderOperator? = nil, value: String = "",
                headerName: String = "", headerSource: CaptureHeaderSource = .original) {
        self.id = id; self.field = field; self.operation = operation ?? field.operations[0]
        self.value = value; self.headerName = headerName; self.headerSource = headerSource
    }
    public var isActive: Bool {
        if field == .active { return true }
        if field == .header { return header.isActive }
        return field.supportsMultipleValues ? !CaptureFilterTerms(value).isEmpty : !value.isEmpty
    }
    private var header: CaptureHeaderCondition {
        .init(name: headerName, operation: operation, value: value)
    }
    func matches(_ record: CaptureRecord) -> Bool? {
        if field == .header {
            guard record.outcome != .tunnel, record.method != "CONNECT",
                  headerSource != .sent || record.hasSentRequestHeaders else { return nil }
            return header.matches(fields: headerSource == .original ? record.requestHeaders : record.sentHeaders,
                                  info: headerSource == .original ? record.requestHeadersInfo : record.sentHeadersInfo)
        }
        if field == .active { return operation == .absent ? !record.connectionState.isActive : record.connectionState.isActive }
        let candidate: String
        switch field {
        case .url: candidate = record.url
        case .domain:
            guard let host = URL(string: record.url)?.host else { return nil }
            candidate = host
        case .method: candidate = record.method
        case .status:
            guard let status = record.status else { return nil }
            candidate = String(status)
        case .project: candidate = record.project
        case .workflow: candidate = record.workflow
        case .environment: candidate = record.environment
        case .outcome: candidate = record.outcome.rawValue
        case .active, .header: return nil
        }
        guard field.supportsMultipleValues else { return candidate == value }
        return CaptureFilterTerms(value).matches { term in
            operation == .contains ? candidate.localizedCaseInsensitiveContains(term)
                : candidate.caseInsensitiveCompare(term) == .orderedSame
        }
    }
}

public struct CaptureFilterGroup: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var combination: CaptureHeaderCombination
    public var conditions: [CaptureFilterCondition]
    public var groups: [CaptureFilterGroup]
    public init(id: UUID = UUID(), combination: CaptureHeaderCombination = .all,
                conditions: [CaptureFilterCondition] = [], groups: [CaptureFilterGroup] = []) {
        self.id = id; self.combination = combination; self.conditions = conditions; self.groups = groups
    }
    public var activeConditionCount: Int {
        conditions.filter(\.isActive).count + groups.reduce(0) { $0 + $1.activeConditionCount }
    }
    func matches(_ record: CaptureRecord) -> Bool? {
        let results = conditions.filter(\.isActive).map { $0.matches(record) }
            + groups.filter { $0.activeConditionCount > 0 }.map { $0.matches(record) }
        return combination.evaluate(results)
    }
}

extension CaptureHeaderCombination {
    /// Empty drafts are omitted before evaluation, including inside an OR group.
    func evaluate(_ results: [Bool?]) -> Bool? {
        guard !results.isEmpty else { return true }
        if self == .all {
            if results.contains(false) { return false }
            return results.contains(where: { $0 == nil }) ? nil : true
        }
        if results.contains(true) { return true }
        return results.contains(where: { $0 == nil }) ? nil : false
    }
}

public struct CaptureRecordFilter: Equatable, Sendable {
    public var conditionGroup: CaptureFilterGroup?
    public var search = ""
    public var resource: CaptureResourceType = .all
    public var project = ""
    public var environment = ""
    public var outcome: CaptureRecord.Outcome?
    public var method = ""
    public var statusCode: Int?
    public var urlContains = ""
    public var domain = ""
    public var headerSource: CaptureHeaderSource = .original
    public var headerCombination: CaptureHeaderCombination = .all
    public var headers: [CaptureHeaderCondition] = []
    public var activeOnly = false
    public var inverted = false
    public init() {}

    public var activeConditionCount: Int {
        [!project.isEmpty, !environment.isEmpty, outcome != nil, !method.isEmpty,
         statusCode != nil, !urlQuery.isEmpty, !domainQuery.isEmpty, activeOnly, inverted].filter { $0 }.count
            + headers.filter(\.isActive).count + (conditionGroup?.activeConditionCount ?? 0)
    }
    public var hasCriteria: Bool {
        !search.isEmpty || resource != .all || activeConditionCount > (inverted ? 1 : 0)
    }
    public func matches(_ record: CaptureRecord, displayOptions: RequestLogDisplayOptions = .init(),
                        searchContext: RequestLogSearchContext = .init()) -> Bool {
        guard hasCriteria else { return true }
        let textMatches = search.isEmpty || RequestLogRow(record: record, displayOptions: displayOptions, context: searchContext)
            .contains(search, displayOptions: displayOptions, allowLAN: searchContext.allowLAN)
        let metadataMatches = textMatches && (resource == .all || CaptureResourceType.classify(record) == resource)
            && (!activeOnly || record.connectionState.isActive)
            && (project.isEmpty || record.project == project)
            && (environment.isEmpty || record.environment == environment)
            && (outcome == nil || record.outcome == outcome)
            && (method.isEmpty || record.method.caseInsensitiveCompare(method) == .orderedSame)
            && (statusCode == nil || record.status == statusCode)
            && (urlQuery.isEmpty || record.url.localizedCaseInsensitiveContains(urlQuery))
            && (domainQuery.isEmpty || URL(string: record.url)?.host?.lowercased() == domainQuery)
        if !metadataMatches { return inverted }
        guard let headerMatches = CaptureHeaderCombination.all.evaluate([matchesHeaders(record), conditionGroup.map { $0.matches(record) } ?? true]) else { return false }
        return inverted ? !headerMatches : headerMatches
    }
    private var urlQuery: String { urlContains.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var domainQuery: String { domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    private func matchesHeaders(_ record: CaptureRecord) -> Bool? {
        let conditions = headers.filter(\.isActive)
        guard !conditions.isEmpty else { return true }
        guard record.outcome != .tunnel, record.method != "CONNECT" else { return nil }
        if headerSource == .sent && !record.hasSentRequestHeaders { return nil }
        let fields = headerSource == .original ? record.requestHeaders : record.sentHeaders
        let info = headerSource == .original ? record.requestHeadersInfo : record.sentHeadersInfo
        let results = conditions.map { $0.matches(fields: fields, info: info) }
        if headerCombination == .all {
            if results.contains(false) { return false }
            return results.contains(where: { $0 == nil }) ? nil : true
        }
        if results.contains(true) { return true }
        return results.contains(where: { $0 == nil }) ? nil : false
    }
}
