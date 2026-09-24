public enum UpstreamRoute: Codable, Equatable, Sendable {
    /// Uses the existing OS route, which may still pass through Surge Enhanced Mode.
    case system
    /// Explicit HTTP proxy; HTTPS traffic will use CONNECT when transport is implemented.
    case httpProxy(ProxyEndpoint)
}
