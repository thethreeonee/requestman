import Foundation
import RequestmanCore
import UserNotifications
import os

/// The adapter lets checks exercise permission and delivery without contacting notificationd.
@MainActor
protocol RuleHitNotificationCenter: AnyObject {
    var delegate: (any UNUserNotificationCenterDelegate)? { get set }
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
}

@MainActor
private final class SystemNotificationCenter: RuleHitNotificationCenter {
    private let center = UNUserNotificationCenter.current()
    var delegate: (any UNUserNotificationCenterDelegate)? {
        get { center.delegate }
        set { center.delegate = newValue }
    }
    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await center.requestAuthorization(options: options)
    }
    func add(_ request: UNNotificationRequest) async throws { try await center.add(request) }
}

@MainActor
final class SystemRuleHitNotifications: NSObject, RuleHitNotificationDelivering, UNUserNotificationCenterDelegate {
    private let center: any RuleHitNotificationCenter
    private let logger = Logger(subsystem: "Requestman", category: "RuleHitNotifications")

    init(center: (any RuleHitNotificationCenter)? = nil) {
        self.center = center ?? SystemNotificationCenter()
        super.init()
        self.center.delegate = self
    }

    func prepareAuthorization() async {
        guard await center.authorizationStatus() == .notDetermined else { return }
        do { _ = try await center.requestAuthorization(options: [.alert]) }
        catch { logger.error("通知授权失败：\(error.localizedDescription, privacy: .public)") }
    }

    func deliver(_ notification: RuleHitNotification, from buffer: RuleHitNotificationBuffer) async {
        let status = await center.authorizationStatus()
        guard status == .authorized || status == .provisional else { return }
        guard !Task.isCancelled, buffer.isCurrent(notification) else { return }
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        // Each round has its own identifier. Reusing it updates only that round's notification.
        let request = UNNotificationRequest(identifier: "rule-hit.\(notification.id.uuidString)",
                                            content: content, trigger: nil)
        do { try await center.add(request) }
        catch { logger.error("规则命中通知发送失败：\(error.localizedDescription, privacy: .public)") }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
