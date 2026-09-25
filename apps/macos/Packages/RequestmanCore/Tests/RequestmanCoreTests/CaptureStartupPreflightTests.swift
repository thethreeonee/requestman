import Foundation
import Testing
@testable import RequestmanCore

@MainActor
struct CaptureStartupPreflightTests {
    private var proxied: ExplicitProxyConfiguration {
        var configuration = ExplicitProxyConfiguration()
        configuration.upstream = .httpProxy(ProxyEndpoint(host: "127.0.0.1", port: 6152))
        return configuration
    }

    @Test func systemRouteSkipsCheckAndPrompt() async throws {
        let configuration = ExplicitProxyConfiguration()
        let result = try await CaptureStartupPreflight.prepare(configuration: configuration) { _ in
            Issue.record("System route must not be probed")
        } decide: { _, _ in
            Issue.record("System route must not prompt")
            return .cancel
        }
        #expect(result == configuration)
    }

    @Test func reachableUpstreamStartsWithoutPrompt() async throws {
        var checks = 0
        let result = try await CaptureStartupPreflight.prepare(configuration: proxied) { endpoint in
            checks += 1
            #expect(endpoint.port == 6152)
        } decide: { _, _ in
            Issue.record("Reachable upstream must not prompt")
            return .cancel
        }
        #expect(result == proxied)
        #expect(checks == 1)
    }

    @Test(arguments: [UpstreamFailureDecision.disableUpstream, .continueWithUpstream])
    func failureRespectsExplicitRouteChoice(_ decision: UpstreamFailureDecision) async throws {
        var events: [String] = []
        let result = try await CaptureStartupPreflight.prepare(configuration: proxied) { _ in
            events.append("check")
            throw WorkflowError.invalid("refused")
        } decide: { endpoint, reason in
            events.append("choose")
            #expect(endpoint.host == "127.0.0.1")
            #expect(reason == "refused")
            return decision
        }
        events.append("ready")
        #expect(events == ["check", "choose", "ready"])
        #expect(result.port == proxied.port)
        switch decision {
        case .disableUpstream: #expect(result.upstream == .system)
        case .continueWithUpstream: #expect(result == proxied)
        case .cancel: Issue.record("Unexpected test case")
        }
    }

    @Test func cancelChoiceNeverReturnsAStartupConfiguration() async {
        await #expect(throws: CancellationError.self) {
            try await CaptureStartupPreflight.prepare(configuration: proxied) { _ in
                throw WorkflowError.invalid("offline")
            } decide: { _, _ in .cancel }
        }
    }

    @Test func cancelledProbeDoesNotAskToOverrideCancellation() async {
        await #expect(throws: CancellationError.self) {
            try await CaptureStartupPreflight.prepare(configuration: proxied) { _ in
                throw CancellationError()
            } decide: { _, _ in
                Issue.record("Cancellation must not open a prompt")
                return .continueWithUpstream
            }
        }
    }

    @Test func invalidLoopConfigurationCannotBeOverridden() async {
        var configuration = proxied
        configuration.port = 6152
        await #expect(throws: WorkflowError.self) {
            try await CaptureStartupPreflight.prepare(configuration: configuration) { _ in
                Issue.record("Invalid configuration must fail before probing")
            } decide: { _, _ in
                Issue.record("Invalid configuration must not be overridable")
                return .continueWithUpstream
            }
        }
    }
}
