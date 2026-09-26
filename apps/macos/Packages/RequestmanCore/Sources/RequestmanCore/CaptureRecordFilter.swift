import Foundation

public enum CaptureResourceType: String, CaseIterable, Sendable {
    case all = "全部", json = "JSON", document = "文档", css = "CSS", script = "JS"
    case image = "图片", font = "字体", media = "媒体", other = "其他"

    public static func classify(_ record: CaptureRecord) -> Self {
        guard record.outcome != .tunnel else { return .other }
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

public struct CaptureRecordFilter: Equatable, Sendable {
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
    public var inverted = false
    public init() {}

    public var activeConditionCount: Int {
        [!project.isEmpty, !environment.isEmpty, outcome != nil, !method.isEmpty,
         statusCode != nil, !urlQuery.isEmpty, !domainQuery.isEmpty, inverted].filter { $0 }.count
            + headers.filter(\.isActive).count
    }
    public var hasCriteria: Bool {
        !search.isEmpty || resource != .all || activeConditionCount > (inverted ? 1 : 0)
    }
    public func matches(_ record: CaptureRecord) -> Bool {
        guard hasCriteria else { return true }
        let textMatches = search.isEmpty || record.url.localizedCaseInsensitiveContains(search)
            || record.workflow.localizedCaseInsensitiveContains(search)
            || record.matchedRules.contains { $0.summary.localizedCaseInsensitiveContains(search) }
        let metadataMatches = textMatches && (resource == .all || CaptureResourceType.classify(record) == resource)
            && (project.isEmpty || record.project == project)
            && (environment.isEmpty || record.environment == environment)
            && (outcome == nil || record.outcome == outcome)
            && (method.isEmpty || record.method.caseInsensitiveCompare(method) == .orderedSame)
            && (statusCode == nil || record.status == statusCode)
            && (urlQuery.isEmpty || record.url.localizedCaseInsensitiveContains(urlQuery))
            && (domainQuery.isEmpty || URL(string: record.url)?.host?.lowercased() == domainQuery)
        if !metadataMatches { return inverted }
        guard let headerMatches = matchesHeaders(record) else { return false }
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
