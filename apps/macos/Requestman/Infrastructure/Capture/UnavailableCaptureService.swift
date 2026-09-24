import Foundation
import RequestmanCore

/// Explicitly unavailable until a real transport and extension lifecycle are implemented.
@MainActor
struct UnavailableCaptureService: CaptureService {
    var availability: CaptureAvailability {
        .unavailable(reason: "流量捕获尚未接入")
    }

    func start(configuration: CaptureConfiguration) async throws {
        try configuration.validate()
        throw CaptureServiceError.notImplemented
    }

    func stop() async throws {
        // No extension or proxy is running in the scaffold.
    }
}

private enum CaptureServiceError: LocalizedError {
    case notImplemented

    var errorDescription: String? { "流量捕获尚未接入。" }
}
