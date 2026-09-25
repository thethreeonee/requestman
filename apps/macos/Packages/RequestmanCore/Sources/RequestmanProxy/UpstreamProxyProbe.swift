import Foundation
import Network
import RequestmanCore

/// Checks TCP reachability only; it does not send a request to a third-party destination.
public enum UpstreamProxyProbe {
    public static func check(_ endpoint: ProxyEndpoint, timeout: Duration = .seconds(3)) async throws {
        try Task.checkCancellation()
        try endpoint.validate()
        guard timeout > .zero else { throw WorkflowError.invalid("连接上游代理超时") }
        guard let port = NWEndpoint.Port(rawValue: UInt16(endpoint.port)) else {
            throw WorkflowError.invalid("上游代理端口无效")
        }
        let attempt = UpstreamConnectionAttempt(host: NWEndpoint.Host(endpoint.host), port: port)
        try await attempt.run(timeout: timeout)
    }
}

/// Continuation, timer and connection teardown are serialized, including cancellation races.
private actor UpstreamConnectionAttempt {
    private let connection: NWConnection
    private var continuation: CheckedContinuation<Void, any Error>?
    private var timeoutTask: Task<Void, Never>?

    init(host: NWEndpoint.Host, port: NWEndpoint.Port) {
        let parameters = NWParameters.tcp
        parameters.preferNoProxies = true
        connection = NWConnection(host: host, port: port, using: parameters)
    }

    func run(timeout: Duration) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                connection.stateUpdateHandler = { [weak self] state in
                    Task { await self?.stateChanged(state) }
                }
                // Total deadline covers resolution and connection setup, including waiting states.
                timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    await self?.finish(.failure(WorkflowError.invalid("连接上游代理超时")))
                }
                connection.start(queue: .global(qos: .utility))
            }
        } onCancel: {
            Task { await self.finish(.failure(CancellationError())) }
        }
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready: finish(.success(()))
        case .failed(let error): finish(.failure(error))
        case .cancelled: finish(.failure(CancellationError()))
        default: break
        }
    }

    private func finish(_ result: Result<Void, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(with: result)
    }
}
