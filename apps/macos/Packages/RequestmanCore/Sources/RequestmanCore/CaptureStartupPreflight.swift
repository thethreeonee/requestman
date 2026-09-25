import Foundation

public enum UpstreamFailureDecision: Sendable {
    case disableUpstream, continueWithUpstream, cancel
}

/// Shared by all host startup actions. No listener or system settings are changed here.
public enum CaptureStartupPreflight {
    @MainActor
    public static func prepare(
        configuration: ExplicitProxyConfiguration,
        checkUpstream: (ProxyEndpoint) async throws -> Void,
        decide: (ProxyEndpoint, String) async -> UpstreamFailureDecision
    ) async throws -> ExplicitProxyConfiguration {
        try Task.checkCancellation()
        try configuration.validate()
        guard case .httpProxy(let endpoint) = configuration.upstream else { return configuration }
        do {
            try await checkUpstream(endpoint)
            try Task.checkCancellation()
            return configuration
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            let decision = await decide(endpoint, error.localizedDescription)
            try Task.checkCancellation()
            switch decision {
            case .disableUpstream:
                var result = configuration
                result.upstream = .system
                return result
            case .continueWithUpstream:
                return configuration
            case .cancel:
                throw CancellationError()
            }
        }
    }
}
