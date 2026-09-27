import Foundation

/// Host boundary for the explicit proxy. Transparent capture remains a separate configuration contract.
@MainActor
public protocol CaptureService {
    var availability: CaptureAvailability { get }
    func start(configuration: CaptureConfiguration) async throws
    func start(configuration: ExplicitProxyConfiguration, document: WorkspaceDocument, mode: CaptureMode) async throws -> Int
    func update(document: WorkspaceDocument) async
    func reconfigure(configuration: ExplicitProxyConfiguration, document: WorkspaceDocument) async throws -> Int
    var recordBuffer: CaptureRecordBuffer? { get }
    var ruleHitNotificationBuffer: RuleHitNotificationBuffer? { get }
    var captureEvents: CaptureEventBuffer? { get }
    /// Retained if system settings could not be restored after a failed start/stop.
    var activePort: Int? { get }
    var activeMode: CaptureMode? { get }
    var activeConfiguration: ExplicitProxyConfiguration? { get }
    func recoverSystemProxy() async throws
    func checkUpstream(_ endpoint: ProxyEndpoint) async throws
    func replay(_ request: RequestReplayDraft) async throws
    func cancelReplay(_ id: UUID) async
    func stop() async throws
}

public extension CaptureService {
    func cancelReplay(_ id: UUID) async {}
    func replay(_ request: RequestReplayDraft) async throws {
        throw WorkflowError.invalid("此捕获服务不支持请求重放")
    }
    func start(configuration: ExplicitProxyConfiguration, document: WorkspaceDocument, mode: CaptureMode) async throws -> Int {
        throw WorkflowError.invalid("此捕获服务不支持显式代理")
    }
    func update(document: WorkspaceDocument) async {}
    func reconfigure(configuration: ExplicitProxyConfiguration, document: WorkspaceDocument) async throws -> Int {
        throw WorkflowError.invalid("此捕获服务不支持实时配置")
    }

    /// Restore the previous configuration after a failed replacement. Keep listeners whose system restore failed.
    func restart(configuration: ExplicitProxyConfiguration, restoring previous: ExplicitProxyConfiguration,
                 document: WorkspaceDocument, mode: CaptureMode) async throws -> Int {
        try configuration.validate()
        try await stop()
        do { return try await start(configuration: configuration, document: document, mode: mode) }
        catch {
            let changeError = error
            if activePort == nil {
                var previousDocument = document
                previousDocument.proxy = previous
                do { _ = try await start(configuration: previous, document: previousDocument, mode: mode) }
                catch {
                    throw WorkflowError.invalid("配置应用失败：\(changeError.localizedDescription)；恢复原配置失败：\(error.localizedDescription)")
                }
            }
            throw changeError
        }
    }
    var recordBuffer: CaptureRecordBuffer? { nil }
    var ruleHitNotificationBuffer: RuleHitNotificationBuffer? { nil }
    var captureEvents: CaptureEventBuffer? { nil }
    var activePort: Int? { nil }
    var activeMode: CaptureMode? { nil }
    var activeConfiguration: ExplicitProxyConfiguration? { nil }
    func recoverSystemProxy() async throws {}
    func checkUpstream(_ endpoint: ProxyEndpoint) async throws {
        throw WorkflowError.invalid("此捕获服务不支持上游连接检查")
    }
}
