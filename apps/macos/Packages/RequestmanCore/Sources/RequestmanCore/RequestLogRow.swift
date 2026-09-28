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
    public let result: String
    public let failure: String?
    public let replay: String?

    public init(record: CaptureRecord, displayOptions: RequestLogDisplayOptions = .init(),
                context: RequestLogSearchContext = .init()) {
        extraValues = Dictionary(uniqueKeysWithValues: displayOptions.extraColumns
            .filter { $0.isEnabled && $0.validationError == nil }
            .map { ($0.identifier, $0.value(in: record) ?? "—") })
        let workflowName = record.matchedWorkflowID.flatMap { context.workflowNames[$0] }
        let deviceAliases = context.deviceAliases
        id = record.id
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
        let seconds = max(0, record.duration)
        duration = record.connectionState.isActive ? record.connectionSummary : seconds >= 1 ? String(format: "%.1f s", seconds) : String(format: "%.0f ms", seconds * 1000)
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

    public func contains(_ query: String, displayOptions: RequestLogDisplayOptions, allowLAN: Bool) -> Bool {
        for column in RequestLogStandardColumn.allCases where displayOptions.isVisible(column, allowLAN: allowLAN) {
            let values: [String]
            switch column {
            case .time: values = [time]
            case .status: values = [status.map(String.init) ?? "—"]
            case .request: values = [method + " " + url, replay ?? failure ?? ""]
            case .rules: values = [project, workflow ?? ""]
            case .device: values = [DeviceSource.title(deviceSource, aliases: deviceSource.map { [$0: deviceAlias] } ?? [:])]
            case .duration: values = [duration]
            }
            if values.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return true }
        }
        return extraValues.values.contains {
            $0.localizedCaseInsensitiveContains(query)
                || $0.replacingOccurrences(of: "\n", with: " · ").localizedCaseInsensitiveContains(query)
        }
    }
}
