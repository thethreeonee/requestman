import Foundation
import Observation
import RequestmanCore

@MainActor
@Observable
final class WorkspaceModel {
    var selection: WorkspaceSection? = .applications
    var applications: [RunningApplication] = []
    var selectedApplicationIDs: Set<String> = []
    var usesHTTPProxy = false
    var proxyHost = "127.0.0.1"
    var proxyPort = "6152"

    @ObservationIgnored private let captureService: any CaptureService
    @ObservationIgnored private let applicationCatalog = ApplicationCatalog()

    init(captureService: any CaptureService = UnavailableCaptureService()) {
        self.captureService = captureService
    }

    var captureAvailability: CaptureAvailability { captureService.availability }

    var upstreamRoute: UpstreamRoute {
        if usesHTTPProxy {
            .httpProxy(ProxyEndpoint(host: proxyHost, port: Int(proxyPort) ?? 0))
        } else {
            .system
        }
    }

    var connectionValidationMessage: String? {
        guard case let .httpProxy(endpoint) = upstreamRoute else { return nil }
        do {
            try endpoint.validate()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func refreshApplications() {
        applications = applicationCatalog.runningApplications()
        selectedApplicationIDs.formIntersection(Set(applications.map(\.id)))
    }

    func captureConfiguration() throws -> CaptureConfiguration {
        let configuration = CaptureConfiguration(
            applicationBundleIdentifiers: selectedApplicationIDs,
            upstreamRoute: upstreamRoute
        )
        try configuration.validate()
        return configuration
    }
}
