import Testing
@testable import RequestmanCore

@MainActor
struct CaptureReconfigurationTests {
    private var updated: ExplicitProxyConfiguration {
        var value = ExplicitProxyConfiguration()
        value.port = 9091
        return value
    }

    @Test func portChangeRestoresSystemBeforeStartingNewListener() async throws {
        let service = RestartCaptureService()
        let port = try await service.restart(configuration: updated, restoring: .init(), document: .init(), mode: .systemProxy)
        #expect(port == 9091)
        #expect(service.events == ["stop", "start:9091"])
    }

    @Test func failedNewListenerRestoresPreviousConfiguration() async {
        let service = RestartCaptureService()
        service.failPorts = [9091]
        await #expect(throws: WorkflowError.self) {
            try await service.restart(configuration: updated, restoring: .init(), document: .init(), mode: .systemProxy)
        }
        #expect(service.events == ["stop", "start:9091", "start:9090"])
        #expect(service.activePort == 9090)
    }

    @Test func failedSystemRestoreKeepsOriginalListener() async {
        let service = RestartCaptureService()
        service.failStop = true
        await #expect(throws: WorkflowError.self) {
            try await service.restart(configuration: updated, restoring: .init(), document: .init(), mode: .systemProxy)
        }
        #expect(service.events == ["stop"])
        #expect(service.activePort == 9090)
    }

    @Test func failedStartWithRetainedListenerDoesNotOverwriteRecovery() async {
        let service = RestartCaptureService()
        service.failPorts = [9091]
        service.retainFailedListener = true
        await #expect(throws: WorkflowError.self) {
            try await service.restart(configuration: updated, restoring: .init(), document: .init(), mode: .systemProxy)
        }
        #expect(service.events == ["stop", "start:9091"])
        #expect(service.activePort == 9091)
    }

    @Test func invalidConfigurationDoesNotInterruptCapture() async {
        let service = RestartCaptureService()
        var invalid = updated
        invalid.port = 0
        await #expect(throws: WorkflowError.self) {
            try await service.restart(configuration: invalid, restoring: .init(), document: .init(), mode: .systemProxy)
        }
        #expect(service.events.isEmpty)
        #expect(service.activePort == 9090)
    }

    @Test func rollbackFailureReportsBothFailures() async {
        let service = RestartCaptureService()
        service.failPorts = [9090, 9091]
        do {
            _ = try await service.restart(configuration: updated, restoring: .init(), document: .init(), mode: .systemProxy)
            Issue.record("Expected reconfiguration to fail")
        } catch {
            #expect(error.localizedDescription.contains("9091"))
            #expect(error.localizedDescription.contains("9090"))
        }
        #expect(service.activePort == nil)
    }
}

@MainActor
private final class RestartCaptureService: CaptureService {
    var availability: CaptureAvailability { .available }
    var activePort: Int? = 9090
    var activeMode: CaptureMode? = .systemProxy
    var events: [String] = []
    var failPorts: Set<Int> = []
    var failStop = false
    var retainFailedListener = false
    func start(configuration: CaptureConfiguration) async throws {}
    func start(configuration: ExplicitProxyConfiguration, document: WorkspaceDocument, mode: CaptureMode) async throws -> Int {
        events.append("start:\(configuration.port)")
        if failPorts.contains(configuration.port) {
            if retainFailedListener { activePort = configuration.port; activeMode = mode }
            throw WorkflowError.invalid("启动失败 \(configuration.port)")
        }
        activePort = configuration.port
        activeMode = mode
        return configuration.port
    }
    func stop() async throws {
        events.append("stop")
        if failStop { throw WorkflowError.invalid("恢复系统代理失败") }
        activePort = nil
        activeMode = nil
    }
}
