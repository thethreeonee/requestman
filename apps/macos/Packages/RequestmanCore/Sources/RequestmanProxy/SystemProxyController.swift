import Foundation
import RequestmanCore

/// Serializes system settings transactions off the main actor. Tests inject an in-memory backend.
public actor SystemProxyController {
    private let backend: any SystemProxyBackend
    private let journalURL: URL

    public init(journalURL: URL) {
        self.journalURL = journalURL
        backend = NetworkPreferencesBackend()
    }

    init(journalURL: URL, backend: sending any SystemProxyBackend) {
        self.journalURL = journalURL
        self.backend = backend
    }

    public func enable(port: Int) throws {
        guard (1024...65535).contains(port) else { throw WorkflowError.invalid("系统代理端口无效") }
        // Never overwrite an outstanding recovery record, including after a failed stop.
        try restore()
        try backend.begin()
        defer { backend.end() }
        let originals = try backend.configurationsForEnabledServices()
        guard !originals.isEmpty else { throw WorkflowError.invalid("没有可设置代理的已启用网络服务") }
        let entries = try originals.map { id, original in
            SystemProxyJournal.Entry(serviceID: id, original: try encode(original),
                                     applied: try encode(SystemProxySettings.applying(port: port, to: original)))
        }
        // Save before the first system write. Commit/apply failure must leave recovery data intact.
        try save(SystemProxyJournal(entries: entries))
        for entry in entries {
            try backend.setConfiguration(try decode(entry.applied), serviceID: entry.serviceID)
        }
        try backend.commitAndApply()
    }

    public func restore() throws {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
        let journal = try PropertyListDecoder().decode(SystemProxyJournal.self, from: Data(contentsOf: journalURL))
        guard journal.version == 1 else { throw WorkflowError.invalid("无法读取系统代理恢复记录") }
        guard !journal.entries.isEmpty else { return }
        try backend.begin()
        defer { backend.end() }
        for entry in journal.entries {
            // A deleted network service does not need restoring; disabled services still do.
            guard let current = try backend.configuration(serviceID: entry.serviceID) else { continue }
            let restored = SystemProxySettings.restoring(current: current,
                original: try decode(entry.original), applied: try decode(entry.applied))
            if !NSDictionary(dictionary: restored).isEqual(to: current) {
                try backend.setConfiguration(restored, serviceID: entry.serviceID)
            }
        }
        // Apply even if a previous attempt committed the restore but failed to apply it.
        try backend.commitAndApply()
        // Atomically replace with an empty journal rather than discard it before apply succeeds.
        try save(SystemProxyJournal(entries: []))
    }

    private func save(_ journal: SystemProxyJournal) throws {
        let directory = journalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let data = try PropertyListEncoder().encode(journal)
        try data.write(to: journalURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
    }

    private func encode(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }
    private func decode(_ value: Data) throws -> [String: Any] {
        guard let dictionary = try PropertyListSerialization.propertyList(from: value, format: nil) as? [String: Any] else {
            throw WorkflowError.invalid("系统代理恢复记录格式错误")
        }
        return dictionary
    }
}

struct SystemProxyJournal: Codable {
    var version = 1
    var entries: [Entry]
    struct Entry: Codable {
        var serviceID: String
        var original: Data
        var applied: Data
    }
}

enum SystemProxySettings {
    // Restore related settings as a group, retaining subsequent edits made by the user or Surge.
    static let groups = [
        ["HTTPEnable", "HTTPProxy", "HTTPPort", "HTTPUser"],
        ["HTTPSEnable", "HTTPSProxy", "HTTPSPort", "HTTPSUser"],
        ["SOCKSEnable", "SOCKSProxy", "SOCKSPort", "SOCKSUser"],
        ["ProxyAutoConfigEnable", "ProxyAutoConfigURLString", "ProxyAutoConfigJavaScript"],
        ["ProxyAutoDiscoveryEnable"],
        ["ExceptionsList", "ExcludeSimpleHostnames"]
    ]

    static func applying(port: Int, to original: [String: Any]) -> [String: Any] {
        var value = original
        for prefix in ["HTTP", "HTTPS"] {
            value["\(prefix)Enable"] = 1
            value["\(prefix)Proxy"] = "127.0.0.1"
            value["\(prefix)Port"] = port
            value.removeValue(forKey: "\(prefix)User")
        }
        value["SOCKSEnable"] = 0
        value["ProxyAutoConfigEnable"] = 0
        value["ProxyAutoDiscoveryEnable"] = 0
        value["ExceptionsList"] = [String]()
        value["ExcludeSimpleHostnames"] = 0
        return value
    }

    static func restoring(current: [String: Any], original: [String: Any], applied: [String: Any]) -> [String: Any] {
        var value = current
        for keys in groups {
            let currentGroup = current.filter { keys.contains($0.key) }
            let appliedGroup = applied.filter { keys.contains($0.key) }
            guard NSDictionary(dictionary: currentGroup).isEqual(to: appliedGroup) else { continue }
            for key in keys { value[key] = original[key] }
        }
        return value
    }
}

/// Called only inside SystemProxyController, with no suspension between lock and unlock.
protocol SystemProxyBackend: AnyObject {
    func begin() throws
    func end()
    func configurationsForEnabledServices() throws -> [String: [String: Any]]
    func configuration(serviceID: String) throws -> [String: Any]?
    func setConfiguration(_ value: [String: Any], serviceID: String) throws
    func commitAndApply() throws
}
