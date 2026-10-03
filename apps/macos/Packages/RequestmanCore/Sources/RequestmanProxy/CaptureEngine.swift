import Foundation
import RequestmanCore
import RequestmanCertificates

/// Owns one listening session. The chosen mode is retained until that session stops.
@MainActor
public final class CaptureEngine: CaptureService {
    private let server: any LocalProxyServing
    private let systemProxy: any SystemProxyManaging
    private var session = CaptureSession()
    public var activePort: Int? { session.port }
    public var activeMode: CaptureMode? { session.mode }
    public var activeConfiguration: ExplicitProxyConfiguration? { session.configuration }
    public var state: CaptureSession.State { session.state }

    public convenience init(journalURL: URL, certificateProvider: (any TLSCertificateProviding)? = nil) {
        self.init(server: LocalProxyServer(certificateProvider: certificateProvider), systemProxy: SystemProxyController(journalURL: journalURL))
    }

    init(server: any LocalProxyServing, systemProxy: any SystemProxyManaging) {
        self.server = server
        self.systemProxy = systemProxy
    }

    public var availability: CaptureAvailability { .available }
    public var captureEvents: CaptureEventBuffer? { server.events }
    public var recordBuffer: CaptureRecordBuffer? { server.records }
    public var ruleHitNotificationBuffer: RuleHitNotificationBuffer? { server.ruleHitNotifications }
    public func makeScriptHTTPClient() async throws -> any ScriptHTTPClient {
        guard state == .running else { throw WorkflowError.invalid("请先启动捕获，再进行脚本真实联调") }
        return try await server.makeScriptHTTPClient()
    }

    public func checkUpstream(_ endpoint: ProxyEndpoint) async throws {
        try await UpstreamProxyProbe.check(endpoint)
    }

    public func start(configuration: CaptureConfiguration) async throws {
        try configuration.validate()
        throw WorkflowError.invalid("按应用透明接管尚未实现，请使用显式代理")
    }

    public func start(configuration: ExplicitProxyConfiguration, document: WorkspaceDocument,
                      mode: CaptureMode) async throws -> Int {
        guard state == .stopped || (state == .recoveryRequired && activePort == nil) else { throw WorkflowError.invalid("代理已启动或正在切换状态") }
        try configuration.validate()
        guard mode == .systemProxy || !session.recoveryRequired else {
            throw WorkflowError.invalid("需要先恢复上次的系统代理设置")
        }
        session.state = .starting
        if mode == .systemProxy {
            do { try await restoreSystemProxy() }
            catch { session.state = .recoveryRequired; throw error }
        }
        server.ruleHitNotifications.startSession(enabled: true)
        let port: Int
        do { port = try await server.start(configuration: configuration, document: document) }
        catch {
            await server.stop()
            server.ruleHitNotifications.stopSession()
            session.state = .stopped
            throw error
        }
        session.port = port
        session.mode = mode
        session.configuration = configuration
        guard mode == .systemProxy else { session.state = .running; server.events.append(.init(.sessionStarted)); return port }
        do {
            session.recoveryRequired = true
            try await systemProxy.enable(port: port)
            session.state = .running
            server.events.append(.init(.sessionStarted))
            return port
        } catch {
            let startError = error
            do { try await stopSession() }
            catch {
                throw WorkflowError.invalid("系统代理接管失败：\(startError.localizedDescription)\n恢复失败，已保留监听，请重试停止捕获：\(error.localizedDescription)")
            }
            throw startError
        }
    }

    public func cancelReplay(_ id: UUID) async { await server.cancelReplay(id) }

    public func replay(_ request: RequestReplayDraft) async throws {
        guard state == .running else { throw WorkflowError.invalid("请先启动捕获，再重放请求") }
        try await server.replay(request)
    }

    public func update(document: WorkspaceDocument) async { await server.update(document) }

    public func reconfigure(configuration: ExplicitProxyConfiguration, document: WorkspaceDocument) async throws -> Int {
        try configuration.validate()
        guard state == .running else { throw WorkflowError.invalid("代理未运行或正在切换状态") }
        guard let previous = session.configuration, let activePort, let activeMode else {
            throw WorkflowError.invalid("代理尚未启动")
        }
        if configuration.port == previous.port && configuration.allowLAN == previous.allowLAN {
            session.state = .reconfiguring
            defer { session.state = .running }
            try await server.updateConfiguration(configuration)
            await server.update(document)
            session.configuration = configuration
            return activePort
        }
        return try await restart(configuration: configuration, restoring: previous, document: document, mode: activeMode)
    }

    /// App startup recovery is separate from browser and proxy-only session lifecycles.
    public func recoverSystemProxy() async throws {
        guard activePort == nil, state == .stopped || state == .recoveryRequired else { return }
        session.state = .recovering
        defer { session.state = session.recoveryRequired ? .recoveryRequired : .stopped }
        try await restoreSystemProxy()
    }

    public func stop() async throws {
        guard [.stopped, .running, .recoveryRequired].contains(state) else {
            throw WorkflowError.invalid("捕获正在切换状态")
        }
        try await stopSession()
    }

    private func stopSession() async throws {
        // A global session must keep forwarding until the system no longer depends on it.
        let hadSession = activePort != nil
        session.state = .stopping
        do {
            if activeMode == .systemProxy || session.recoveryRequired { try await restoreSystemProxy() }
        } catch {
            session.state = .recoveryRequired
            throw error
        }
        await server.stop()
        server.ruleHitNotifications.stopSession()
        session.port = nil
        session.mode = nil
        session.configuration = nil
        session.state = .stopped
        if hadSession { server.events.append(.init(.sessionStopped)) }
    }

    private func restoreSystemProxy() async throws {
        do {
            try await systemProxy.restore()
            session.recoveryRequired = false
        } catch {
            session.recoveryRequired = true
            throw error
        }
    }
}

protocol LocalProxyServing: Sendable {
    var events: CaptureEventBuffer { get }
    var records: CaptureRecordBuffer { get }
    var ruleHitNotifications: RuleHitNotificationBuffer { get }
    func start(configuration: ExplicitProxyConfiguration, document: WorkspaceDocument) async throws -> Int
    func update(_ document: WorkspaceDocument) async
    func updateConfiguration(_ configuration: ExplicitProxyConfiguration) async throws
    func replay(_ request: RequestReplayDraft) async throws
    func cancelReplay(_ id: UUID) async
    func makeScriptHTTPClient() async throws -> any ScriptHTTPClient
    func stop() async
}

protocol SystemProxyManaging: Sendable {
    func enable(port: Int) async throws
    func restore() async throws
}

extension LocalProxyServer: LocalProxyServing {}
extension SystemProxyController: SystemProxyManaging {}

extension LocalProxyServing {
    func makeScriptHTTPClient() async throws -> any ScriptHTTPClient {
        throw WorkflowError.invalid("此代理不支持脚本真实联调")
    }
    func cancelReplay(_ id: UUID) async {}
    func replay(_ request: RequestReplayDraft) async throws { throw WorkflowError.invalid("此代理不支持请求重放") }
}
