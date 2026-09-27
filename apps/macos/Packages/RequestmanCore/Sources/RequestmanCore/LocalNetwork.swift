import Foundation
import Darwin

/// Numeric interface addresses only; discovery never performs DNS or changes network settings.
public enum LocalNetwork {
    public struct Address: Equatable, Sendable {
        public let interface: String
        public let host: String
        public var title: String { "\(host)（\(interface)）" }
        public func setupURL(port: Int) -> URL {
            URL(string: "http://\(host):\(port)/requestman")!
        }
    }

    public static func addresses() -> [Address] {
        interfaceAddresses().filter { !$0.host.hasPrefix("127.") && !$0.host.contains(":") }
    }

    private static func interfaceAddresses() -> [Address] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var result: [Address] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let value = entry.pointee
            guard value.ifa_flags & UInt32(IFF_UP) != 0, let address = value.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) || address.pointee.sa_family == UInt8(AF_INET6) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            result.append(Address(interface: String(cString: value.ifa_name), host: String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)))
        }
        return result.sorted { ($0.interface, $0.host) < ($1.interface, $1.host) }
    }

    public static func normalizedHost(_ host: String) -> String {
        let value = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return value.hasPrefix("::ffff:") ? String(value.dropFirst(7)) : value
    }

    public static func isLoopback(_ host: String) -> Bool {
        let host = normalizedHost(host)
        return host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }

    public static func isLocalHost(_ host: String) -> Bool {
        let host = normalizedHost(host)
        return isLoopback(host) || host == "0.0.0.0" || host == "::"
            || interfaceAddresses().contains { normalizedHost($0.host) == host }
    }
}

public enum DeviceSource {
    public static func identifier(for host: String) -> String {
        LocalNetwork.isLoopback(host) ? "local" : LocalNetwork.normalizedHost(host)
    }
    public static func title(_ source: String?, aliases: [String: String] = [:]) -> String {
        guard let source else { return "未知设备" }
        if let alias = aliases[source], !alias.isEmpty { return alias }
        return source == "local" ? "本机" : source
    }
}
