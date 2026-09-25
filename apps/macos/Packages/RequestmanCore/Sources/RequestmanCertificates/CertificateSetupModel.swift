import Foundation
import Observation

public enum CertificateSetupPhase: Sendable {
    case idle, checking, generating, installing, trusting, verifying, complete, cancelled, failed

    public var isRunning: Bool {
        switch self {
        case .checking, .generating, .installing, .trusting, .verifying: true
        default: false
        }
    }
}

/// Coordinates the user-initiated setup. Completed steps survive cancellation and retries.
@MainActor @Observable
public final class CertificateSetupModel {
    public private(set) var status: CertificateStatus?
    public private(set) var phase: CertificateSetupPhase = .idle
    public private(set) var errorMessage: String?
    public var isRunning: Bool { phase.isRunning }
    public var isConfigured: Bool {
        guard let status else { return false }
        return status.generated && status.installed && status.trusted && !status.isExpired
    }

    @ObservationIgnored private let service: any CertificateService

    public init(service: any CertificateService) { self.service = service }

    /// Refresh display state without generating, installing or changing trust settings.
    public func refreshStatus() async {
        guard !isRunning else { return }
        phase = .checking
        errorMessage = nil
        do {
            status = try await service.status()
            phase = isConfigured ? .complete : .idle
        } catch {
            status = nil
            errorMessage = error.localizedDescription
            phase = .idle
        }
    }

    public func run() async {
        guard !isRunning else { return }
        status = nil
        errorMessage = nil
        phase = .checking
        do {
            do {
                status = try await service.status()
            } catch LocalCertificateError.authorizationRequired {
                // Only this user-initiated path may repair the key's persistent signing ACL.
                phase = .generating
                status = try await service.generate()
            }
            try validateValidity()
            try Task.checkCancellation()
            if status?.generated != true {
                phase = .generating
                status = try await service.generate()
            }
            guard status?.generated == true else { throw SetupError.incomplete }
            try validateValidity()
            try Task.checkCancellation()
            if status?.installed != true {
                phase = .installing
                status = try await service.install()
            }
            guard status?.installed == true else { throw SetupError.incomplete }
            try Task.checkCancellation()
            if status?.trusted != true {
                phase = .trusting
                status = try await service.trust()
            }
            phase = .verifying
            status = nil // A failed silent verification must not retain setup's trusted snapshot.
            status = try await service.status()
            try validateValidity()
            guard status?.generated == true, status?.installed == true, status?.trusted == true else {
                throw SetupError.incomplete
            }
            phase = .complete
        } catch is CancellationError {
            phase = .cancelled
            errorMessage = "设置已取消，已完成的步骤会保留。"
        } catch {
            phase = .failed
            errorMessage = error.localizedDescription
        }
    }

    private func validateValidity() throws {
        if status?.isExpired == true { throw LocalCertificateError.expiredCertificate }
    }

    private enum SetupError: LocalizedError {
        case incomplete
        var errorDescription: String? {
            switch self {
            case .incomplete: "证书设置尚未生效，请重试或在钥匙串访问中检查信任状态。"
            }
        }
    }
}
