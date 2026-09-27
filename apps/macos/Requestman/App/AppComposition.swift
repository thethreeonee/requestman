import Foundation
import RequestmanCore
import RequestmanCertificates

/// Creates production services; WorkspaceModel receives the same dependencies as tests.
@MainActor
final class AppComposition {
    let ruleHitNotifications = SystemRuleHitNotifications()

    func makeWorkspace() -> WorkspaceModel {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Requestman", isDirectory: true)
        let certificates = LocalCertificateService(
            directoryURL: directory.appendingPathComponent("Certificates", isDirectory: true)
        )
        return WorkspaceModel(
            captureService: LocalCaptureService(certificateProvider: certificates),
            certificateSetup: CertificateSetupModel(service: certificates),
            documentStore: WorkspaceDocumentStore(url: directory.appendingPathComponent("workspace.json")),
            ruleHitNotifications: ruleHitNotifications
        )
    }
}
