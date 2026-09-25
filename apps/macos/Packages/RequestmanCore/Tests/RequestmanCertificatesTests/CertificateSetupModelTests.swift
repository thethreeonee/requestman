import Foundation
import Testing
@testable import RequestmanCertificates

@MainActor
struct CertificateSetupModelTests {
    @Test func creationDoesNotChangeKeychainUntilUserStarts() async {
        let service = SetupServiceFixture()
        let model = CertificateSetupModel(service: service)
        #expect(model.phase == .idle)
        #expect(await service.events.isEmpty)
    }

    @Test func completesEveryStepAndVerifiesFinalState() async {
        let service = SetupServiceFixture()
        let model = CertificateSetupModel(service: service)
        await model.run()
        #expect(await service.events == ["status", "generate", "install", "trust", "status"])
        #expect(model.phase == .complete)
        #expect(model.status?.trusted == true)
        #expect(model.errorMessage == nil)
    }

    @Test func startupMigratesOnceAndLaterActivationsOnlyRefresh() async {
        let service = SetupServiceFixture(status: .init(generated: true, installed: true, trusted: true))
        let model = CertificateSetupModel(service: service)
        await model.prepareForStartup()
        #expect(model.isConfigured)
        await model.prepareForStartup()
        #expect(await service.events == ["migrate", "status"])
        #expect(await service.migrationInteraction == [false])
    }

    @Test func deniedStartupMigrationDoesNotPromptOrRetryUntilExplicitSetup() async {
        let service = SetupServiceFixture(status: .init(generated: true, installed: true, trusted: true),
                                          requiresAuthorization: true)
        let model = CertificateSetupModel(service: service)
        await model.prepareForStartup()
        #expect(!model.isConfigured)
        #expect(!model.canRegenerate)
        #expect(model.errorMessage == LocalCertificateError.authorizationRequired.localizedDescription)
        await model.prepareForStartup()
        #expect(await service.events == ["migrate", "status"])
        #expect(await service.migrationInteraction == [false])
        await model.run()
        #expect(model.isConfigured)
    }

    @Test func reusesAlreadyTrustedCertificateWithoutWriting() async {
        let service = SetupServiceFixture(status: .init(generated: true, installed: true, trusted: true))
        let model = CertificateSetupModel(service: service)
        await model.run()
        #expect(await service.events == ["status", "status"])
        #expect(model.phase == .complete)
    }

    @Test func refreshRestoresConfiguredStateWithoutChangingTrust() async {
        let service = SetupServiceFixture(status: .init(generated: true, installed: true, trusted: true))
        let model = CertificateSetupModel(service: service)
        await model.refreshStatus()
        #expect(model.isConfigured)
        #expect(model.phase == .complete)
        #expect(await service.events == ["status"])
        await service.makeStatusUnavailable()
        await model.refreshStatus()
        #expect(!model.isConfigured)
        #expect(model.status == nil)
        #expect(await service.events == ["status", "status"])
    }

    @Test func refreshDoesNotTreatExpiredOrIncompleteStateAsConfigured() async {
        for status in [CertificateStatus.missing,
                       .init(generated: true, installed: true),
                       .init(generated: true, installed: true, trusted: true, isExpired: true)] {
            let service = SetupServiceFixture(status: status)
            let model = CertificateSetupModel(service: service)
            await model.refreshStatus()
            #expect(!model.isConfigured)
            #expect(model.phase == .idle)
            #expect(await service.events == ["status"])
        }
    }

    @Test func cancelledAuthorizationCanResumeWithoutRegenerating() async {
        let service = SetupServiceFixture(cancelTrustOnce: true)
        let model = CertificateSetupModel(service: service)
        await model.run()
        #expect(model.phase == .cancelled)
        #expect(model.status?.installed == true)
        #expect(model.status?.trusted == false)
        await model.run()
        #expect(await service.events == ["status", "generate", "install", "trust", "status", "trust", "status"])
        #expect(model.phase == .complete)
        #expect(model.errorMessage == nil)
    }

    @Test func installFailureStopsBeforeAskingForTrust() async {
        let service = SetupServiceFixture(failInstall: true)
        let model = CertificateSetupModel(service: service)
        await model.run()
        #expect(model.phase == .failed)
        #expect(model.status?.generated == true)
        #expect(await service.events == ["status", "generate", "install"])
    }

    @Test func rejectsSuccessWhenFinalTrustCheckFails() async {
        let service = SetupServiceFixture(failVerification: true)
        let model = CertificateSetupModel(service: service)
        await model.run()
        #expect(model.phase == .failed)
        #expect(model.status?.trusted == false)
        #expect(model.errorMessage != nil)
    }

    @Test func missingAuthorizationIsRepairedOnlyDuringExplicitSetup() async {
        let service = SetupServiceFixture(status: .init(generated: true, installed: true, trusted: true),
                                          requiresAuthorization: true)
        let model = CertificateSetupModel(service: service)
        await model.refreshStatus()
        #expect(!model.isConfigured)
        #expect(model.errorMessage == LocalCertificateError.authorizationRequired.localizedDescription)
        #expect(await service.events == ["status"])
        await model.run()
        #expect(model.phase == .complete)
        #expect(await service.events == ["status", "status", "generate", "status"])
    }

    @Test func setupCannotCompleteIfSilentAuthorizationStillFails() async {
        let service = SetupServiceFixture(status: .init(generated: true, installed: true, trusted: true),
                                          requiresAuthorization: true, repairTakesEffect: false)
        let model = CertificateSetupModel(service: service)
        await model.run()
        #expect(model.phase == .failed)
        #expect(!model.isConfigured)
        #expect(model.errorMessage == LocalCertificateError.authorizationRequired.localizedDescription)
    }

    @Test func expiredCertificateIsNotAutomaticallyReplaced() async {
        let service = SetupServiceFixture(status: .init(generated: true, installed: true, isExpired: true))
        let model = CertificateSetupModel(service: service)
        await model.run()
        #expect(model.phase == .failed)
        #expect(await service.events == ["status"])
    }

    @Test func failedRefreshDoesNotKeepAnOldTrustedState() async {
        let service = SetupServiceFixture(status: .init(generated: true, installed: true, trusted: true))
        let model = CertificateSetupModel(service: service)
        await model.run()
        #expect(model.phase == .complete)
        await service.makeStatusUnavailable()
        await model.run()
        #expect(model.phase == .failed)
        #expect(model.status == nil)
    }

    @Test func missingKeyOffersRegenerationButNeverStartsItAutomatically() async {
        let service = SetupServiceFixture()
        await service.makeStatusUnavailable()
        let model = CertificateSetupModel(service: service)
        await model.refreshStatus()
        #expect(model.canRegenerate)
        await model.run()
        #expect(model.phase == .failed)
        #expect(model.canRegenerate)
        #expect(await service.events == ["status", "status"])
        await model.regenerate()
        #expect(model.phase == .complete)
        #expect(!model.canRegenerate)
        #expect(await service.events == ["status", "status", "regenerate", "install", "trust", "status"])
    }

    @Test func regenerationCancellationCanBeRetried() async {
        let service = SetupServiceFixture(cancelRegenerateOnce: true)
        await service.makeStatusUnavailable()
        let model = CertificateSetupModel(service: service)
        await model.run()
        await model.regenerate()
        #expect(model.phase == .cancelled)
        #expect(model.canRegenerate)
        await model.regenerate()
        #expect(model.phase == .complete)
        #expect(await service.events.filter { $0 == "regenerate" }.count == 2)
    }

    @Test func healthyOrUnauthorizedCertificateDoesNotOfferRegeneration() async {
        let service = SetupServiceFixture(status: .init(generated: true, installed: true, trusted: true))
        let model = CertificateSetupModel(service: service)
        await model.run()
        #expect(!model.canRegenerate)
        await model.regenerate()
        #expect(await service.events == ["status", "status"])
        let deniedService = SetupServiceFixture(requiresAuthorization: true, repairTakesEffect: false)
        let denied = CertificateSetupModel(service: deniedService)
        await denied.refreshStatus()
        #expect(!denied.canRegenerate)
    }

    @Test func repeatedClickCannotStartAnotherAuthorization() async {
        let service = SetupServiceFixture(blockTrust: true)
        let model = CertificateSetupModel(service: service)
        let firstRun = Task { await model.run() }
        await service.waitForTrust()
        #expect(model.phase == .trusting)
        await model.refreshStatus()
        #expect(model.phase == .trusting)
        #expect(await service.events.filter { $0 == "status" }.count == 1)
        await model.run()
        #expect(await service.events.filter { $0 == "trust" }.count == 1)
        await service.finishTrust()
        await firstRun.value
        #expect(model.phase == .complete)
    }
}

private actor SetupServiceFixture: CertificateService {
    var events: [String] = []
    var migrationInteraction: [Bool] = []
    private var current: CertificateStatus
    private var cancelTrustOnce: Bool
    private var cancelRegenerateOnce: Bool
    private let failInstall: Bool
    private let failVerification: Bool
    private let blockTrust: Bool
    private var statusReadCount = 0
    private var statusUnavailable = false
    private var requiresAuthorization: Bool
    private let repairTakesEffect: Bool
    private var trustContinuation: CheckedContinuation<Void, Never>?
    private var trustObserver: CheckedContinuation<Void, Never>?

    init(status: CertificateStatus = .missing, cancelTrustOnce: Bool = false,
         failInstall: Bool = false, failVerification: Bool = false, blockTrust: Bool = false,
         requiresAuthorization: Bool = false, repairTakesEffect: Bool = true, cancelRegenerateOnce: Bool = false) {
        current = status
        self.cancelTrustOnce = cancelTrustOnce
        self.cancelRegenerateOnce = cancelRegenerateOnce
        self.failInstall = failInstall
        self.failVerification = failVerification
        self.blockTrust = blockTrust
        self.requiresAuthorization = requiresAuthorization
        self.repairTakesEffect = repairTakesEffect
    }

    func status() async throws -> CertificateStatus {
        events.append("status")
        if requiresAuthorization { throw LocalCertificateError.authorizationRequired }
        if statusUnavailable { throw LocalCertificateError.missingPrivateKey }
        statusReadCount += 1
        if failVerification, statusReadCount > 1 { current.trusted = false }
        return current
    }

    func makeStatusUnavailable() { statusUnavailable = true }

    func generate() async throws -> CertificateStatus {
        events.append("generate")
        if repairTakesEffect { requiresAuthorization = false }
        current.generated = true
        return current
    }

    func migrateAuthorization(allowingUI: Bool) async throws -> CertificateStatus {
        events.append("migrate")
        migrationInteraction.append(allowingUI)
        if allowingUI && repairTakesEffect { requiresAuthorization = false }
        if requiresAuthorization { throw LocalCertificateError.authorizationRequired }
        return current
    }

    func regenerate() async throws -> CertificateStatus {
        events.append("regenerate")
        if cancelRegenerateOnce {
            cancelRegenerateOnce = false
            throw CancellationError()
        }
        statusUnavailable = false
        current = .init(generated: true)
        return current
    }

    func install() async throws -> CertificateStatus {
        events.append("install")
        if failInstall { throw LocalCertificateError.security(operation: "安装证书", status: -1) }
        current.installed = true
        return current
    }

    func trust() async throws -> CertificateStatus {
        events.append("trust")
        if cancelTrustOnce {
            cancelTrustOnce = false
            throw CancellationError()
        }
        if blockTrust {
            await withCheckedContinuation { continuation in
                trustContinuation = continuation
                trustObserver?.resume()
                trustObserver = nil
            }
        }
        current.trusted = true
        return current
    }

    func waitForTrust() async {
        if trustContinuation != nil { return }
        await withCheckedContinuation { trustObserver = $0 }
    }

    func finishTrust() {
        trustContinuation?.resume()
        trustContinuation = nil
    }
}
