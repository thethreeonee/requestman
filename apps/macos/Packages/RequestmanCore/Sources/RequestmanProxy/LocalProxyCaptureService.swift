import Foundation
import RequestmanCore
import RequestmanCertificates

/// Owns one listening session. The chosen mode is retained until that session stops.
@MainActor
public final class LocalProxyCaptureService: CaptureService {
    private let server: any LocalProxyServing
    private let systemProxy: any SystemProxyManaging
    public private(set) var activePort: Int?
    public private(set) var activeMode: CaptureMode?
    private var activeConfiguration: ExplicitProxyConfiguration?
    private var recoveryRequired = false

    public convenience init(journalURL: URL, certificateProvider: (any TLSCertificateProviding)? = nil) {
        self.init(server: LocalProxyServer(certificateProvider: certificateProvider), systemProxy: SystemProxyController(journalURL: journalURL))
    }

    init(server: any LocalProxyServing, systemProxy: any SystemProxyManaging) {
        self.server = server
        self.systemProxy = systemProxy
    }

    public var availability: CaptureAvailability { .available }
    public var recordBuffer: CaptureRecordBuffer? { server.records }

    public func checkUpstream(_ endpoint: ProxyEndpoint) async throws {
        try await UpstreamProxyProbe.check(endpoint)
    }

    public func start(configuration: CaptureConfiguration) async throws {
        try configuration.validate()
        throw WorkflowError.invalid("按应用透明接管尚未实现，请使用显式代理")
    }

    public func start(configuration: ExplicitProxyConfiguration, document: WorkspaceDocument,
                      mode: CaptureMode) async throws -> Int {
        guard activePort == nil else { throw WorkflowError.invalid("代理已启动") }
        try configuration.validate()
        guard mode != .browser || !recoveryRequired else {
            throw WorkflowError.invalid("需要先恢复上次的系统代理设置")
        }
        if mode == .systemProxy { try await recoverSystemProxy() }
        let port: Int
        do { port = try await server.start(configuration: configuration, document: document) }
        catch {
            await server.stop()
            throw error
        }
        activePort = port
        activeMode = mode
        activeConfiguration = configuration
        guard mode == .systemProxy else { return port }
        do {
            recoveryRequired = true
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

    public func update(document: WorkspaceDocument) async { await server.update(document) }

    public func reconfigure(configuration: ExplicitProxyConfiguration, document: WorkspaceDocument) async throws -> Int {
        try configuration.validate()
        guard let previous = activeConfiguration, let activePort, let activeMode else {
            throw WorkflowError.invalid("代理尚未启动")
        }
        if configuration.port == previous.port {
            try await server.updateConfiguration(configuration)
            await server.update(document)
            activeConfiguration = configuration
            return activePort
        }
        return try await restart(configuration: configuration, restoring: previous, document: document, mode: activeMode)
    }

    /// App startup recovery is separate from browser-only session lifecycle.
    public func recoverSystemProxy() async throws {
        guard activePort == nil else { return }
        try await restoreSystemProxy()
    }

    public func stop() async throws {
        // A global session must keep forwarding until the system no longer depends on it.
        if activeMode == .systemProxy || recoveryRequired { try await restoreSystemProxy() }
        await server.stop()
        activePort = nil
        activeMode = nil
        activeConfiguration = nil
    }

    private func restoreSystemProxy() async throws {
        do {
            try await systemProxy.restore()
            recoveryRequired = false
        } catch {
            recoveryRequired = true
            throw error
        }
    }
}

protocol LocalProxyServing: Sendable {
    var records: CaptureRecordBuffer { get }
    func start(configuration: ExplicitProxyConfiguration, document: WorkspaceDocument) async throws -> Int
    func update(_ document: WorkspaceDocument) async
    func updateConfiguration(_ configuration: ExplicitProxyConfiguration) async throws
    func stop() async
}

protocol SystemProxyManaging: Sendable {
    func enable(port: Int) async throws
    func restore() async throws
}

extension LocalProxyServer: LocalProxyServing {}
extension SystemProxyController: SystemProxyManaging {}
