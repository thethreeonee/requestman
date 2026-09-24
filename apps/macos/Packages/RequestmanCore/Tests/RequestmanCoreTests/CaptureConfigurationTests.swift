import Foundation
import Testing
@testable import RequestmanCore

@Test func emptySelectionCannotBecomeGlobalCapture() {
    let configuration = CaptureConfiguration(applicationBundleIdentifiers: [], upstreamRoute: .system)
    #expect(throws: CaptureConfigurationError.noApplications) { try configuration.validate() }
}

@Test(arguments: [0, -1, 65536])
func rejectsInvalidProxyPorts(port: Int) {
    #expect(throws: CaptureConfigurationError.invalidProxyPort) {
        try ProxyEndpoint(host: "127.0.0.1", port: port).validate()
    }
}

@Test(arguments: ["", " ", "http://localhost", "localhost/path", "user@localhost"])
func rejectsURLsAndCredentialsAsHosts(host: String) {
    #expect(throws: CaptureConfigurationError.invalidProxyHost) {
        try ProxyEndpoint(host: host, port: 6152).validate()
    }
}

@Test func explicitSurgeRouteSurvivesSerialization() throws {
    let configuration = CaptureConfiguration(
        applicationBundleIdentifiers: ["com.example.Target"],
        upstreamRoute: .httpProxy(ProxyEndpoint(host: "127.0.0.1", port: 6152))
    )
    try configuration.validate()
    let data = try JSONEncoder().encode(configuration)
    #expect(try JSONDecoder().decode(CaptureConfiguration.self, from: data) == configuration)
}
