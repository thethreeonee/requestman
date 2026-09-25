/// Host boundary for the explicit proxy. Transparent capture remains a separate configuration contract.
@MainActor
public protocol CaptureService {
    var availability: CaptureAvailability { get }
    func start(configuration: CaptureConfiguration) async throws
    func start(configuration: ExplicitProxyConfiguration, document: WorkspaceDocument) async throws -> Int
    func update(document: WorkspaceDocument) async
    var recordBuffer: CaptureRecordBuffer? { get }
    /// Retained if system settings could not be restored after a failed start/stop.
    var activePort: Int? { get }
    func recoverSystemProxy() async throws
    func checkUpstream(_ endpoint: ProxyEndpoint) async throws
    func stop() async throws
}

public extension CaptureService {
    func start(configuration: ExplicitProxyConfiguration, document: WorkspaceDocument) async throws -> Int {
        throw WorkflowError.invalid("此捕获服务不支持显式代理")
    }
    func update(document: WorkspaceDocument) async {}
    var recordBuffer: CaptureRecordBuffer? { nil }
    var activePort: Int? { nil }
    func recoverSystemProxy() async throws {}
    func checkUpstream(_ endpoint: ProxyEndpoint) async throws {
        throw WorkflowError.invalid("此捕获服务不支持上游连接检查")
    }
}
