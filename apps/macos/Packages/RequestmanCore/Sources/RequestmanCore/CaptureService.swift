/// The host app boundary. A future implementation owns extension activation and IPC.
@MainActor
public protocol CaptureService {
    var availability: CaptureAvailability { get }
    func start(configuration: CaptureConfiguration) async throws
    func stop() async throws
}
