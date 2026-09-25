import Foundation
import Security
import SystemConfiguration
import RequestmanCore

/// Native Authorization Services supplies the administrator prompt; no shell or stored password.
final class NetworkPreferencesBackend: SystemProxyBackend {
    private var authorization: AuthorizationRef?
    private var preferences: SCPreferences?

    deinit {
        if let authorization { AuthorizationFree(authorization, []) }
    }

    func begin() throws {
        if authorization == nil {
            let status = AuthorizationCreate(nil, nil, [], &authorization)
            guard status == errAuthorizationSuccess else {
                throw WorkflowError.invalid("无法请求修改系统代理的权限（\(status)）")
            }
        }
        guard let prefs = SCPreferencesCreateWithAuthorization(nil, "Requestman" as CFString, nil, authorization) else {
            throw failure("无法打开网络设置")
        }
        // Do not wait indefinitely if another network configuration utility is updating settings.
        guard SCPreferencesLock(prefs, false) else { throw failure("无法授权或锁定网络设置，请重试") }
        preferences = prefs
    }

    func end() {
        if let preferences { SCPreferencesUnlock(preferences) }
        preferences = nil
    }

    func configurationsForEnabledServices() throws -> [String: [String: Any]] {
        let prefs = try session()
        guard let set = SCNetworkSetCopyCurrent(prefs),
              let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else {
            throw failure("无法读取当前网络位置")
        }
        var result: [String: [String: Any]] = [:]
        for service in services where SCNetworkServiceGetEnabled(service) {
            guard let id = SCNetworkServiceGetServiceID(service) as String?,
                  let proxy = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies),
                  SCNetworkProtocolGetEnabled(proxy) else { continue }
            result[id] = SCNetworkProtocolGetConfiguration(proxy) as? [String: Any] ?? [:]
        }
        return result
    }

    func configuration(serviceID: String) throws -> [String: Any]? {
        guard let service = SCNetworkServiceCopy(try session(), serviceID as CFString) else {
            try requireMissingEntity()
            return nil
        }
        guard let proxy = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else {
            try requireMissingEntity()
            return nil
        }
        return SCNetworkProtocolGetConfiguration(proxy) as? [String: Any] ?? [:]
    }

    func setConfiguration(_ value: [String: Any], serviceID: String) throws {
        guard let service = SCNetworkServiceCopy(try session(), serviceID as CFString),
              let proxy = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies),
              SCNetworkProtocolSetConfiguration(proxy, value as CFDictionary) else {
            throw failure("无法更新网络服务的代理设置")
        }
    }

    func commitAndApply() throws {
        let prefs = try session()
        guard SCPreferencesCommitChanges(prefs) else { throw failure("无法保存系统代理设置") }
        guard SCPreferencesApplyChanges(prefs) else { throw failure("无法应用系统代理设置") }
    }

    private func session() throws -> SCPreferences {
        guard let preferences else { throw WorkflowError.invalid("网络设置会话未开启") }
        return preferences
    }
    private func requireMissingEntity() throws {
        let code = SCError()
        guard code == kSCStatusNoKey else {
            throw failure("无法读取待恢复的网络服务")
        }
    }
    private func failure(_ message: String) -> WorkflowError {
        .invalid("\(message)：\(String(cString: SCErrorString(SCError())))")
    }
}
