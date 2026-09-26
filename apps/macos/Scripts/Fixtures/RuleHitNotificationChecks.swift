import Foundation
import RequestmanCore
import UserNotifications

@MainActor
private final class NotificationCenterFake: RuleHitNotificationCenter {
    var delegate: (any UNUserNotificationCenterDelegate)?
    var status: UNAuthorizationStatus = .notDetermined
    var authorizationRequests: [UNAuthorizationOptions] = []
    var requests: [UNNotificationRequest] = []
    var failNextAdd = false
    var onStatus: (() -> Void)?
    func authorizationStatus() async -> UNAuthorizationStatus {
        onStatus?()
        return status
    }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        authorizationRequests.append(options)
        status = .authorized
        return true
    }
    func add(_ request: UNNotificationRequest) async throws {
        if failNextAdd {
            failNextAdd = false
            throw NSError(domain: "NotificationCenterFake", code: 1)
        }
        requests.append(request)
    }
}

@main
struct RuleHitNotificationChecks {
    @MainActor static func main() async {
        let center = NotificationCenterFake()
        let notifications = SystemRuleHitNotifications(center: center)
        precondition(center.delegate === notifications)
        await notifications.prepareAuthorization()
        await notifications.prepareAuthorization()
        precondition(center.authorizationRequests == [.alert], "Request permission once, without sounds or badges")

        let buffer = RuleHitNotificationBuffer()
        buffer.startSession(enabled: true)
        let start = ContinuousClock.now
        buffer.append(workflowID: UUID(), name: "用户信息 Mock", at: start)
        let first = buffer.drain()[0]
        await notifications.deliver(first, from: buffer)
        buffer.append(workflowID: UUID(), name: "登录 Header 修改", at: start.advanced(by: .seconds(2)))
        await notifications.deliver(buffer.drain()[0], from: buffer)
        buffer.append(workflowID: UUID(), name: "商品列表替换", at: start.advanced(by: .milliseconds(3200)))
        let second = buffer.drain()[0]
        await notifications.deliver(second, from: buffer)
        precondition(center.requests.count == 3)
        precondition(center.requests[0].identifier == center.requests[1].identifier)
        precondition(center.requests[1].identifier != center.requests[2].identifier)
        precondition(center.requests.map(\.content.body) == ["用户信息 Mock", "用户信息 Mock\n登录 Header 修改", "商品列表替换"])
        precondition(center.requests.allSatisfy {
            $0.content.title == "规则命中" && $0.content.subtitle.isEmpty && $0.content.sound == nil && $0.trigger == nil
        })

        center.status = .denied
        await notifications.prepareAuthorization()
        await notifications.deliver(second, from: buffer)
        precondition(center.requests.count == 3 && center.authorizationRequests.count == 1)
        center.status = .authorized
        center.failNextAdd = true
        await notifications.deliver(second, from: buffer)
        await notifications.deliver(second, from: buffer)
        precondition(center.requests.count == 4, "A delivery failure must not stop later notifications")

        center.onStatus = { buffer.stopSession() }
        await notifications.deliver(second, from: buffer)
        precondition(center.requests.count == 4, "Stopping capture while querying permission invalidates the delivery")
        print("Rule notification checks passed: authorization, silent immediate requests, fixed-window identifiers/content, denial, delivery failure and stale-session rejection. No system notification sent.")
    }
}
