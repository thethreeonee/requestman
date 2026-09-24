import Foundation

public struct ProxyEndpoint: Codable, Equatable, Sendable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    public func validate() throws {
        // A host is not a URL. The transport will handle DNS and IPv6 resolution.
        guard !host.isEmpty,
              !host.contains(where: { $0.isWhitespace }),
              !host.contains("://"),
              !host.contains(where: { "/?#@".contains($0) }) else {
            throw CaptureConfigurationError.invalidProxyHost
        }
        guard (1...65535).contains(port) else {
            throw CaptureConfigurationError.invalidProxyPort
        }
    }
}
