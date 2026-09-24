public struct CaptureConfiguration: Codable, Equatable, Sendable {
    /// UI selection only. The future provider must resolve signing identities and helpers.
    public var applicationBundleIdentifiers: Set<String>
    public var upstreamRoute: UpstreamRoute

    public init(applicationBundleIdentifiers: Set<String>, upstreamRoute: UpstreamRoute) {
        self.applicationBundleIdentifiers = applicationBundleIdentifiers
        self.upstreamRoute = upstreamRoute
    }

    public func validate() throws {
        guard !applicationBundleIdentifiers.isEmpty,
              applicationBundleIdentifiers.allSatisfy({ !$0.isEmpty }) else {
            throw CaptureConfigurationError.noApplications
        }
        if case let .httpProxy(endpoint) = upstreamRoute {
            try endpoint.validate()
        }
    }
}
