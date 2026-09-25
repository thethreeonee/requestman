import Foundation
import Testing
import RequestmanCore
@testable import RequestmanProxy

struct SystemProxyTests {
    @Test func restoresSurgePACSOCKSAndBypassWithoutChangingUnrelatedValues() {
        let original: [String: Any] = [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 6152,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 6152,
            "ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "https://example.test/proxy.pac",
            "SOCKSEnable": 1, "SOCKSPort": 6153, "ExceptionsList": ["*.local"],
            "ExcludeSimpleHostnames": 1, "Unrelated": "retained"
        ]
        let applied = SystemProxySettings.applying(port: 9090, to: original)
        #expect(applied["HTTPPort"] as? Int == 9090)
        #expect(applied["HTTPSPort"] as? Int == 9090)
        #expect(applied["SOCKSEnable"] as? Int == 0)
        #expect(applied["ProxyAutoConfigEnable"] as? Int == 0)
        #expect(applied["ExceptionsList"] as? [String] == [])
        #expect(NSDictionary(dictionary: SystemProxySettings.restoring(current: applied, original: original, applied: applied)).isEqual(to: original))
    }

    @Test func retainsExternalChangesButRestoresRemainingOwnedSettings() {
        let original: [String: Any] = ["HTTPEnable": 0, "HTTPSPort": 6152,
                                       "ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "https://old.test/proxy.pac"]
        let applied = SystemProxySettings.applying(port: 9090, to: original)
        var current = applied
        current["HTTPPort"] = 7890
        current["ExceptionsList"] = ["new.test"]
        current["Unrelated"] = "new"
        current["ProxyAutoConfigURLString"] = "https://new.test/proxy.pac"
        let restored = SystemProxySettings.restoring(current: current, original: original, applied: applied)
        #expect(restored["HTTPPort"] as? Int == 7890)
        #expect(restored["HTTPEnable"] as? Int == 1)
        #expect(restored["HTTPSPort"] as? Int == 6152)
        #expect(restored["HTTPSProxy"] == nil)
        #expect(restored["HTTPSEnable"] == nil)
        #expect(restored["ExceptionsList"] as? [String] == ["new.test"])
        #expect(restored["Unrelated"] as? String == "new")
        #expect(restored["ProxyAutoConfigEnable"] as? Int == 0)
        #expect(restored["ProxyAutoConfigURLString"] as? String == "https://new.test/proxy.pac")
    }

    @Test func durableRecoveryRestoresMultipleServicesAfterRelaunch() async throws {
        let original: [String: [String: Any]] = ["wifi": ["HTTPPort": 6152], "ethernet": [:]]
        let backend = TestNetworkPreferences(original)
        let url = temporaryJournal()
        let controller = SystemProxyController(journalURL: url, backend: backend)
        try await controller.enable(port: 9090)
        #expect(backend.snapshot()["wifi"]?["HTTPPort"] as? Int == 9090)
        #expect(backend.snapshot()["ethernet"]?["HTTPSPort"] as? Int == 9090)
        let journal = try PropertyListDecoder().decode(SystemProxyJournal.self, from: Data(contentsOf: url))
        #expect(journal.entries.count == 2)
        let relaunched = SystemProxyController(journalURL: url, backend: backend)
        try await relaunched.restore()
        #expect(NSDictionary(dictionary: backend.snapshot()).isEqual(to: original))
        let calls = backend.beginCount
        try await relaunched.restore()
        #expect(backend.beginCount == calls) // Empty recovery records never ask for authorization.
    }

    @Test func applyFailureKeepsJournalAndCanBeRolledBack() async throws {
        let original: [String: [String: Any]] = ["wifi": ["HTTPPort": 6152]]
        let backend = TestNetworkPreferences(original)
        backend.failNextApply()
        let url = temporaryJournal()
        let controller = SystemProxyController(journalURL: url, backend: backend)
        await #expect(throws: WorkflowError.self) { try await controller.enable(port: 9090) }
        #expect(backend.snapshot()["wifi"]?["HTTPPort"] as? Int == 9090)
        #expect(try PropertyListDecoder().decode(SystemProxyJournal.self, from: Data(contentsOf: url)).entries.count == 1)
        try await controller.restore()
        #expect(NSDictionary(dictionary: backend.snapshot()).isEqual(to: original))
    }

    @Test func failedRestoreCanRetryAfterSettingsWereAlreadyCommitted() async throws {
        let original: [String: [String: Any]] = ["wifi": [:]]
        let backend = TestNetworkPreferences(original)
        let url = temporaryJournal()
        let controller = SystemProxyController(journalURL: url, backend: backend)
        try await controller.enable(port: 9090)
        backend.failNextApply()
        await #expect(throws: WorkflowError.self) { try await controller.restore() }
        #expect(try PropertyListDecoder().decode(SystemProxyJournal.self, from: Data(contentsOf: url)).entries.count == 1)
        try await controller.restore()
        #expect(NSDictionary(dictionary: backend.snapshot()).isEqual(to: original))
        #expect(try PropertyListDecoder().decode(SystemProxyJournal.self, from: Data(contentsOf: url)).entries.isEmpty)
    }

    @Test func deniedAuthorizationAndNoEligibleServicesNeverWriteSettings() async throws {
        let denied = TestNetworkPreferences(["wifi": [:]])
        denied.denyNextBegin()
        let url = temporaryJournal()
        let controller = SystemProxyController(journalURL: url, backend: denied)
        await #expect(throws: WorkflowError.self) { try await controller.enable(port: 9090) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(denied.snapshot()["wifi"]?.isEmpty == true)
        let empty = SystemProxyController(journalURL: temporaryJournal(), backend: TestNetworkPreferences([:]))
        await #expect(throws: WorkflowError.self) { try await empty.enable(port: 9090) }
    }

    @Test func corruptJournalPreventsTakeover() async throws {
        let backend = TestNetworkPreferences(["wifi": [:]])
        let url = temporaryJournal()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("invalid journal".utf8).write(to: url)
        let controller = SystemProxyController(journalURL: url, backend: backend)
        await #expect(throws: (any Error).self) { try await controller.enable(port: 9090) }
        #expect(backend.beginCount == 0)
    }

    private func temporaryJournal() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("requestman-system-proxy-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent("recovery.plist")
    }
}

/// All mutable state is locked; tests inspect only between awaited controller calls.
private final class TestNetworkPreferences: SystemProxyBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [String: Any]]
    private var pending: [String: [String: Any]] = [:]
    private var applyFails = false
    private var beginFails = false
    private var begins = 0
    init(_ values: [String: [String: Any]]) { self.values = values }
    var beginCount: Int { lock.withLock { begins } }
    func snapshot() -> [String: [String: Any]] { lock.withLock { values } }
    func failNextApply() { lock.withLock { applyFails = true } }
    func denyNextBegin() { lock.withLock { beginFails = true } }
    func begin() throws {
        try lock.withLock {
            begins += 1
            if beginFails { beginFails = false; throw WorkflowError.invalid("authorization denied") }
            pending = values
        }
    }
    func end() { lock.withLock { pending = [:] } }
    func configurationsForEnabledServices() -> [String: [String: Any]] { lock.withLock { pending } }
    func configuration(serviceID: String) -> [String: Any]? { lock.withLock { pending[serviceID] } }
    func setConfiguration(_ value: [String: Any], serviceID: String) { lock.withLock { pending[serviceID] = value } }
    func commitAndApply() throws {
        try lock.withLock {
            values = pending
            if applyFails { applyFails = false; throw WorkflowError.invalid("apply failed after commit") }
        }
    }
}
