import Foundation

/// Workspace values that affect the text currently presented in the log.
public struct RequestLogSearchContext: Sendable {
    public var allowLAN: Bool
    public var workflowNames: [UUID: String]
    public var deviceAliases: [String: String]

    public init(allowLAN: Bool = false, workflowNames: [UUID: String] = [:], deviceAliases: [String: String] = [:]) {
        self.allowLAN = allowLAN
        self.workflowNames = workflowNames
        self.deviceAliases = deviceAliases
    }
}

/// Shared text for table cells and visible-column search, before width truncation.
public struct RequestLogRow: Equatable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let time: String
    public let method: String
    public let url: String
    public let project: String
    public let workflow: String?
    public let deviceSource: String?
    public let deviceAlias: String
    public let extraValues: [String: String]
    public let status: Int?
    public let duration: String
    public let durationSeconds: Double
    public let result: String
    public let failure: String?
    public let replay: String?
    private let fieldSnapshot: RequestLogFieldSnapshot
    private let hasMatchedRules: Bool
    private let activeConnectionSummary: String?

    public init(record: CaptureRecord, displayOptions: RequestLogDisplayOptions = .init(),
                context: RequestLogSearchContext = .init()) {
        extraValues = Dictionary(uniqueKeysWithValues: displayOptions.extraColumns
            .filter { $0.isEnabled && $0.validationError == nil }
            .compactMap { column in column.value(in: record).map { (column.identifier, $0) } })
        fieldSnapshot = RequestLogFieldSnapshot(record: record)
        hasMatchedRules = record.matchedWorkflowID != nil || !record.matchedRules.isEmpty
        let workflowName = record.matchedWorkflowID.flatMap { context.workflowNames[$0] }
        let deviceAliases = context.deviceAliases
        id = record.id
        startedAt = record.startedAt
        time = Self.timeFormatter.string(from: record.startedAt)
        method = record.captureProtocol == .http ? record.method : record.captureProtocol == .sse ? "SSE" : "WS"
        url = record.url
        project = record.project
        workflow = record.matchedWorkflowID != nil
            ? (record.archivedAt == nil ? workflowName ?? record.workflow : record.workflow)
            : record.matchedRules.first?.name
        deviceSource = record.deviceSource
        deviceAlias = record.deviceSource.flatMap { deviceAliases[$0] } ?? ""
        status = record.status
        durationSeconds = record.duration.isFinite ? max(0, record.duration) : 0
        activeConnectionSummary = record.connectionState.isActive ? record.connectionSummary : nil
        duration = activeConnectionSummary ?? Self.formattedDuration(durationSeconds, appearance: .init())
        result = record.replaySummary ?? record.error.map { "\(record.outcome.rawValue) · \($0)" } ?? record.outcome.rawValue
        replay = record.replaySummary
        failure = record.error ?? (record.outcome == .failed ? record.outcome.rawValue : nil)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let millisecondTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    public func contains(_ query: String, displayOptions: RequestLogDisplayOptions, allowLAN: Bool) -> Bool {
        for column in displayOptions.layoutColumns where displayOptions.isColumnVisible(column.id, allowLAN: allowLAN) {
            for line in renderedLines(in: column, allowLAN: allowLAN) {
                let values = line.contents.map(\.text)
                let displayed = line.contents.map(\.displayText)
                let searchable = values + displayed + [values.joined(separator: " "), displayed.joined(separator: " ")]
                if searchable.contains(where: {
                    $0.localizedCaseInsensitiveContains(query)
                        || $0.replacingOccurrences(of: "\n", with: " · ").localizedCaseInsensitiveContains(query)
                }) { return true }
            }
        }
        return false
    }

    public func renderedLines(in column: RequestLogLayoutColumn, allowLAN: Bool) -> [RequestLogRenderedLine] {
        column.lines.compactMap { line in
            let contents = line.contents.compactMap { content -> RequestLogRenderedContent? in
                guard content.validationError == nil, content.field != .device || allowLAN else { return nil }
                let captured = value(for: content)
                let text: String
                if let captured, !captured.isEmpty, !captured.allSatisfy(\.isNewline) {
                    text = captured
                } else {
                    guard content.emptyBehavior == .customText, !content.emptyText.isEmpty else { return nil }
                    text = content.emptyText
                }
                return .init(configuration: content, text: text, valueCount: repeatedValueCount(for: content))
            }
            return contents.isEmpty ? nil : .init(id: line.id, contents: contents)
        }
    }

    private func value(for content: RequestLogLayoutContent) -> String? {
        switch content.field {
        case .time:
            return content.appearance.timePrecision == .milliseconds ? Self.millisecondTimeFormatter.string(from: startedAt) : time
        case .duration: return activeConnectionSummary ?? Self.formattedDuration(durationSeconds, appearance: content.appearance)
        case .ruleGroup: return hasMatchedRules ? project : nil
        case .rule: return hasMatchedRules ? workflow : nil
        case .rules:
            guard hasMatchedRules else { return nil }
            let values = [project, workflow ?? ""].filter { !$0.isEmpty }
            let separator: String
            switch content.appearance.ruleSeparator {
            case .automatic, .newLine: separator = "\n"
            case .dot: separator = " · "
            case .slash: separator = " / "
            case .arrow: separator = " → "
            }
            return values.isEmpty ? nil : values.joined(separator: separator)
        case .device:
            guard let deviceSource, !deviceSource.isEmpty else { return nil }
            return DeviceSource.title(deviceSource, aliases: [deviceSource: deviceAlias])
        case .detail: return replay ?? failure
        case .method where content.stage == .originalRequest: return method
        case .url where content.stage == .originalRequest: return url
        case .status:
            guard let value = fieldSnapshot.value(field: .status, stage: content.stage, name: "") else { return nil }
            guard content.appearance.showsStatusDescription, let code = Int(value) else { return value }
            return value + " " + Self.statusDescription(code)
        default:
            guard let field = content.field.extraField else { return nil }
            return fieldSnapshot.value(field: field, stage: content.stage,
                                       name: content.name.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func repeatedValueCount(for content: RequestLogLayoutContent) -> Int? {
        let name = content.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.field == .header {
            let fields: [HTTPField]
            switch content.stage {
            case .originalRequest: fields = fieldSnapshot.requestHeaders
            case .sentRequest: fields = fieldSnapshot.sentHeaders
            case .originalResponse: fields = fieldSnapshot.receivedHeaders
            case .returnedResponse: fields = fieldSnapshot.responseHeaders
            }
            return fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.count
        }
        guard content.field == .queryParameter else { return nil }
        guard content.stage == .originalRequest || fieldSnapshot.hasSentRequestHeaders,
              !(content.stage == .originalRequest ? fieldSnapshot.urlWasTruncated : fieldSnapshot.finalURLWasTruncated) else { return 0 }
        let text = content.stage == .originalRequest ? fieldSnapshot.url : fieldSnapshot.finalURL
        guard let address = URLComponents(string: text), address.scheme != nil, address.host != nil else { return 0 }
        return address.queryItems?.filter { $0.name == name }.count ?? 0
    }

    private static func formattedDuration(_ seconds: Double, appearance: RequestLogContentAppearance) -> String {
        let usesSeconds = appearance.durationUnit == .seconds || appearance.durationUnit == .automatic && seconds >= 1
        let digits: Int
        switch appearance.durationPrecision {
        case .automatic: digits = usesSeconds ? 1 : 0
        case .whole: digits = 0
        case .tenths: digits = 1
        case .hundredths: digits = 2
        }
        return String(format: "%.*f %@", locale: Locale(identifier: "en_US_POSIX"),
                      digits, usesSeconds ? seconds : seconds * 1000, usesSeconds ? "s" : "ms")
    }

    private static func statusDescription(_ code: Int) -> String {
        switch code {
        case 100: "Continue"
        case 101: "Switching Protocols"
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 204: "No Content"
        case 206: "Partial Content"
        case 301: "Moved Permanently"
        case 302: "Found"
        case 303: "See Other"
        case 304: "Not Modified"
        case 307: "Temporary Redirect"
        case 308: "Permanent Redirect"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 410: "Gone"
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        case 418: "I'm a teapot"
        case 422: "Unprocessable Content"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        default: HTTPURLResponse.localizedString(forStatusCode: code)
        }
    }
}
