import Foundation
import Testing
@testable import RequestmanCore

struct MobileCaptureTests {
    @Test func oldWorkspacesAndRecordsRemainReadable() throws {
        let document = WorkspaceDocument()
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
        var proxy = try #require(json["proxy"] as? [String: Any])
        proxy.removeValue(forKey: "allowLAN"); json["proxy"] = proxy
        json.removeValue(forKey: "deviceAliases")
        let restored = try JSONDecoder().decode(WorkspaceDocument.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!restored.proxy.allowLAN && restored.deviceAliases.isEmpty)
        let record = CaptureRecord(method: "GET", url: "http://example.test")
        let oldRecord = try JSONDecoder().decode(CaptureRecord.self, from: JSONEncoder().encode(record))
        #expect(oldRecord.deviceSource == nil)
        #expect(DeviceSource.title(oldRecord.deviceSource) == "未知设备")
    }

    @Test func aliasesAndSourceSurviveArchives() throws {
        var document = WorkspaceDocument()
        document.proxy.allowLAN = true
        document.deviceAliases = ["192.168.1.20": "测试 iPhone", "local": "开发 Mac"]
        let restored = try JSONDecoder().decode(WorkspaceDocument.self, from: JSONEncoder().encode(document))
        #expect(restored.proxy.allowLAN && restored.deviceAliases == document.deviceAliases)
        var record = CaptureRecord(method: "GET", url: "http://example.test")
        record.deviceSource = "192.168.1.20"
        let saved = try JSONDecoder().decode(CaptureRecord.self, from: JSONEncoder().encode(record))
        #expect(saved.deviceSource == record.deviceSource)
        #expect(DeviceSource.title(saved.deviceSource, aliases: restored.deviceAliases) == "测试 iPhone")
        #expect(DeviceSource.identifier(for: "::ffff:192.168.1.20") == "192.168.1.20")
        #expect(DeviceSource.identifier(for: "127.0.0.1") == DeviceSource.identifier(for: "::1"))
    }

    @Test func upstreamCannotPointAtAnyLocalListenerAddress() throws {
        for host in ["127.0.0.1", "localhost", "0.0.0.0", "::1"] + LocalNetwork.addresses().map(\.host) {
            var config = ExplicitProxyConfiguration(); config.allowLAN = true
            config.upstream = .httpProxy(ProxyEndpoint(host: host, port: config.port))
            #expect(throws: WorkflowError.self) { try config.validate() }
            config.upstream = .httpProxy(ProxyEndpoint(host: host, port: config.port + 1))
            try config.validate()
        }
    }
}
