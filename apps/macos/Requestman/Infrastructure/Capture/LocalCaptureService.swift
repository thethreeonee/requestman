import Foundation
import RequestmanCore
import RequestmanProxy

@MainActor
final class LocalCaptureService: CaptureService {
    private let server = LocalProxyServer()
    private let systemProxy: SystemProxyController
    private(set) var activePort: Int?
    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Requestman", isDirectory: true)
        systemProxy = SystemProxyController(journalURL: directory.appendingPathComponent("system-proxy-recovery.plist"))
    }
    var availability: CaptureAvailability { .available }
    var recordBuffer: CaptureRecordBuffer? { server.records }
    func checkUpstream(_ endpoint: ProxyEndpoint) async throws {
        try await UpstreamProxyProbe.check(endpoint)
    }
    func start(configuration: CaptureConfiguration) async throws {
        try configuration.validate()
        throw WorkflowError.invalid("按应用透明接管尚未实现，请使用 Chrome 显式代理")
    }
    func start(configuration: ExplicitProxyConfiguration, document: WorkspaceDocument) async throws -> Int {
        try await recoverSystemProxy()
        let port = try await server.start(configuration: configuration, document: document)
        activePort = port
        do {
            try await systemProxy.enable(port: port)
            return port
        } catch {
            let startError = error
            do { try await stop() }
            catch {
                throw WorkflowError.invalid("系统代理接管失败：\(startError.localizedDescription)\n恢复失败，已保留监听，请重试停止捕获：\(error.localizedDescription)")
            }
            throw startError
        }
    }
    func update(document: WorkspaceDocument) async { await server.update(document) }
    func recoverSystemProxy() async throws {
        guard activePort == nil else { return }
        try await systemProxy.restore()
    }
    func stop() async throws {
        // Keep forwarding until the system no longer depends on this listener.
        try await systemProxy.restore()
        await server.stop()
        activePort = nil
    }
}
