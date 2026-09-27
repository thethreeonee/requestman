import RequestmanCore

/// Listening lifecycle. Failed restoration keeps the listener available until recovery succeeds.
public struct CaptureSession {
    public enum State: Equatable, Sendable {
        case stopped
        case recovering
        case reconfiguring
        case starting
        case running
        case stopping
        case recoveryRequired
    }

    var state: State = .stopped
    var port: Int?
    var mode: CaptureMode?
    var configuration: ExplicitProxyConfiguration?
    var recoveryRequired = false
}
