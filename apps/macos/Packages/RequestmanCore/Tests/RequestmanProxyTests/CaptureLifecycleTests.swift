import Testing
import RequestmanCore
@testable import RequestmanProxy

@MainActor
struct CaptureLifecycleTests {
    @Test func browserSessionNeverReadsOrWritesSystemProxy() async throws {
        let fixture = CaptureFixture()
        let service = fixture.service
        #expect(try await service.start(configuration: .init(), document: .init(), mode: .browser) == 9090)
        #expect(service.activeMode == .browser)

        var updated = ExplicitProxyConfiguration()
        updated.upstream = .httpProxy(ProxyEndpoint(host: "127.0.0.1", port: 6152))
        #expect(try await service.reconfigure(configuration: updated, document: .init()) == 9090)
        #expect(fixture.server.configuration == updated)
        #expect(service.activeMode == .browser)

        updated.port = 9091
        #expect(try await service.reconfigure(configuration: updated, document: .init()) == 9091)
        #expect(service.activeMode == .browser)
        try await service.stop()
        #expect(service.activePort == nil)
        #expect(service.activeMode == nil)
        #expect(fixture.system.calls.isEmpty)
    }

    @Test func browserListenerFailureCleansUpWithoutTouchingSystemProxy() async {
        let fixture = CaptureFixture()
        fixture.server.failPorts = [9090]
        await #expect(throws: WorkflowError.self) {
            try await fixture.service.start(configuration: .init(), document: .init(), mode: .browser)
        }
        #expect(fixture.trace.events == ["listen:9090", "stop"])
        #expect(fixture.server.configuration == nil)
        #expect(fixture.service.activePort == nil)
        #expect(fixture.service.activeMode == nil)
        #expect(fixture.system.calls.isEmpty)
    }

    @Test(arguments: CaptureMode.allCases)
    func failedPortChangeRestoresPreviousConfigurationAndMode(mode: CaptureMode) async throws {
        let fixture = CaptureFixture()
        var previous = ExplicitProxyConfiguration()
        previous.upstream = .httpProxy(ProxyEndpoint(host: "127.0.0.1", port: 6152))
        _ = try await fixture.service.start(configuration: previous, document: .init(), mode: mode)
        var updated = ExplicitProxyConfiguration()
        updated.port = 9091
        fixture.server.failPorts = [9091]
        await #expect(throws: WorkflowError.self) {
            try await fixture.service.reconfigure(configuration: updated, document: .init())
        }
        #expect(fixture.service.activePort == 9090)
        #expect(fixture.service.activeMode == mode)
        #expect(fixture.server.configuration == previous)
        #expect(fixture.server.document?.proxy == previous)
        if mode == .browser {
            #expect(fixture.system.calls.isEmpty)
        } else {
            #expect(fixture.system.calls.filter { $0 == "enable:9090" }.count == 2)
        }
        try await fixture.service.stop()
    }

    @Test func systemSessionStartsListenerBeforeTakeoverAndRestoresBeforeStop() async throws {
        let fixture = CaptureFixture()
        _ = try await fixture.service.start(configuration: .init(), document: .init(), mode: .systemProxy)
        #expect(fixture.service.activeMode == .systemProxy)
        try await fixture.service.stop()
        #expect(fixture.trace.events == ["restore", "listen:9090", "enable:9090", "restore", "stop"])
        #expect(fixture.service.activeMode == nil)
    }

    @Test func failedSystemTakeoverRestoresBeforeClosingListener() async {
        let fixture = CaptureFixture()
        fixture.system.failEnable = true
        await #expect(throws: WorkflowError.self) {
            try await fixture.service.start(configuration: .init(), document: .init(), mode: .systemProxy)
        }
        #expect(fixture.trace.events == ["restore", "listen:9090", "enable:9090", "restore", "stop"])
        #expect(fixture.service.activePort == nil)
        #expect(fixture.service.activeMode == nil)
    }

    @Test func failedTakeoverRecoveryRetainsSystemModeUntilStopSucceeds() async throws {
        let fixture = CaptureFixture()
        fixture.system.failEnable = true
        fixture.system.failRestoreAfterEnable = true
        await #expect(throws: WorkflowError.self) {
            try await fixture.service.start(configuration: .init(), document: .init(), mode: .systemProxy)
        }
        #expect(fixture.service.activePort == 9090)
        #expect(fixture.service.activeMode == .systemProxy)
        #expect(fixture.server.configuration?.port == 9090)
        #expect(!fixture.trace.events.contains("stop"))
        fixture.system.failRestore = false
        try await fixture.service.stop()
        #expect(fixture.trace.events.suffix(2) == ["restore", "stop"])
        #expect(fixture.service.activeMode == nil)
    }

    @Test func failedSystemRestoreKeepsListenerAndPreventsPortOrModeReplacement() async throws {
        let fixture = CaptureFixture()
        _ = try await fixture.service.start(configuration: .init(), document: .init(), mode: .systemProxy)
        fixture.system.failRestore = true
        var updated = ExplicitProxyConfiguration()
        updated.port = 9091
        await #expect(throws: WorkflowError.self) {
            try await fixture.service.reconfigure(configuration: updated, document: .init())
        }
        await #expect(throws: WorkflowError.self) {
            try await fixture.service.start(configuration: updated, document: .init(), mode: .browser)
        }
        #expect(fixture.service.activePort == 9090)
        #expect(fixture.service.activeMode == .systemProxy)
        #expect(fixture.server.configuration?.port == 9090)
        #expect(!fixture.trace.events.contains("stop"))
        #expect(!fixture.trace.events.contains("listen:9091"))
        fixture.system.failRestore = false
        try await fixture.service.stop()
    }

    @Test func systemPortChangeRetainsTakeoverAndCanThenStartBrowserOnly() async throws {
        let fixture = CaptureFixture()
        _ = try await fixture.service.start(configuration: .init(), document: .init(), mode: .systemProxy)
        fixture.trace.events.removeAll()
        var updated = ExplicitProxyConfiguration()
        updated.port = 9091
        #expect(try await fixture.service.reconfigure(configuration: updated, document: .init()) == 9091)
        #expect(fixture.trace.events == ["restore", "stop", "restore", "listen:9091", "enable:9091"])
        #expect(fixture.service.activeMode == .systemProxy)
        try await fixture.service.stop()
        let systemCalls = fixture.system.calls
        _ = try await fixture.service.start(configuration: .init(), document: .init(), mode: .browser)
        #expect(fixture.service.activeMode == .browser)
        try await fixture.service.stop()
        #expect(fixture.system.calls == systemCalls)
    }

    @Test func startupRecoveryIsIndependentFromBrowserSessionAndIdleStop() async throws {
        let fixture = CaptureFixture()
        try await fixture.service.stop()
        #expect(fixture.system.calls.isEmpty)
        try await fixture.service.recoverSystemProxy()
        #expect(fixture.system.calls == ["restore"])
        _ = try await fixture.service.start(configuration: .init(), document: .init(), mode: .browser)
        try await fixture.service.recoverSystemProxy()
        try await fixture.service.stop()
        #expect(fixture.system.calls == ["restore"])
    }

    @Test func failedStartupRecoveryBlocksBrowserAndKeepsStopRecoveryRequired() async throws {
        let fixture = CaptureFixture()
        fixture.system.failRestore = true
        await #expect(throws: WorkflowError.self) { try await fixture.service.recoverSystemProxy() }
        await #expect(throws: WorkflowError.self) {
            try await fixture.service.start(configuration: .init(), document: .init(), mode: .browser)
        }
        #expect(fixture.trace.events == ["restore"])
        await #expect(throws: WorkflowError.self) { try await fixture.service.stop() }
        #expect(fixture.trace.events == ["restore", "restore"])
        #expect(fixture.service.activePort == nil)
        #expect(fixture.service.activeMode == nil)
        fixture.system.failRestore = false
        try await fixture.service.stop()
        #expect(fixture.trace.events.suffix(2) == ["restore", "stop"])
        let systemCalls = fixture.system.calls
        _ = try await fixture.service.start(configuration: .init(), document: .init(), mode: .browser)
        try await fixture.service.stop()
        #expect(fixture.system.calls == systemCalls)
    }
}

@MainActor
private struct CaptureFixture {
    let trace: CaptureTrace
    let server: TestLocalProxyServer
    let system: TestSystemProxyManager
    let service: LocalProxyCaptureService

    init() {
        let trace = CaptureTrace()
        let server = TestLocalProxyServer(trace: trace)
        let system = TestSystemProxyManager(trace: trace)
        self.trace = trace
        self.server = server
        self.system = system
        service = LocalProxyCaptureService(server: server, systemProxy: system)
    }
}

@MainActor
private final class CaptureTrace {
    var events: [String] = []
}

@MainActor
private final class TestLocalProxyServer: LocalProxyServing {
    nonisolated let records = CaptureRecordBuffer()
    let trace: CaptureTrace
    var configuration: ExplicitProxyConfiguration?
    var document: WorkspaceDocument?
    var failPorts: Set<Int> = []

    init(trace: CaptureTrace) { self.trace = trace }
    func start(configuration: ExplicitProxyConfiguration, document: WorkspaceDocument) async throws -> Int {
        trace.events.append("listen:\(configuration.port)")
        self.configuration = configuration
        self.document = document
        if failPorts.contains(configuration.port) { throw WorkflowError.invalid("端口不可用") }
        return configuration.port
    }
    func update(_ document: WorkspaceDocument) async { self.document = document }
    func updateConfiguration(_ configuration: ExplicitProxyConfiguration) async throws { self.configuration = configuration }
    func stop() async {
        trace.events.append("stop")
        configuration = nil
    }
}

@MainActor
private final class TestSystemProxyManager: SystemProxyManaging {
    let trace: CaptureTrace
    var calls: [String] = []
    var failEnable = false
    var failRestore = false
    var failRestoreAfterEnable = false

    init(trace: CaptureTrace) { self.trace = trace }
    func enable(port: Int) async throws {
        calls.append("enable:\(port)")
        trace.events.append("enable:\(port)")
        if failRestoreAfterEnable { failRestore = true }
        if failEnable { throw WorkflowError.invalid("接管失败") }
    }
    func restore() async throws {
        calls.append("restore")
        trace.events.append("restore")
        if failRestore { throw WorkflowError.invalid("恢复失败") }
    }
}
