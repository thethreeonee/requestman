import Foundation
import Testing
@testable import RequestmanCore

struct RuleHitNotificationTests {
    @Test func fixedWindowMatchesZeroTwoAndThreePointTwoSeconds() throws {
        let buffer = RuleHitNotificationBuffer()
        buffer.startSession(enabled: true)
        let start = ContinuousClock.now
        buffer.append(workflowID: UUID(), name: "规则 A", at: start)
        let first = try #require(buffer.drain().first)
        #expect(first.title == "规则命中")
        #expect(first.body == "规则 A")
        buffer.append(workflowID: UUID(), name: "规则 B", at: start.advanced(by: .seconds(2)))
        let updated = try #require(buffer.drain().first)
        #expect(updated.id == first.id)
        #expect(updated.body == "规则 A\n规则 B")
        buffer.append(workflowID: UUID(), name: "规则 C", at: start.advanced(by: .milliseconds(3200)))
        let second = try #require(buffer.drain().first)
        #expect(second.id != first.id)
        #expect(second.body == "规则 C")
    }

    @Test func exactBoundaryStartsNewRoundEvenForTheSameRule() throws {
        let buffer = RuleHitNotificationBuffer()
        buffer.startSession(enabled: true)
        let start = ContinuousClock.now, ruleID = UUID()
        buffer.append(workflowID: ruleID, name: "规则 A", at: start)
        let first = try #require(buffer.drain().first)
        buffer.append(workflowID: ruleID, name: "规则 A", at: start.advanced(by: .milliseconds(2999)))
        #expect(buffer.drain().isEmpty)
        buffer.append(workflowID: ruleID, name: "规则 A", at: start.advanced(by: .seconds(3)))
        let next = try #require(buffer.drain().first)
        #expect(next.id != first.id)
        #expect(next.names == ["规则 A"])
        #expect(buffer.drain().isEmpty) // Expiry itself never emits a notification.
    }

    @Test func coalescesUnreadUpdatesButKeepsDifferentRoundsAndDistinctRuleIDs() throws {
        let buffer = RuleHitNotificationBuffer()
        buffer.startSession(enabled: true)
        let start = ContinuousClock.now, ruleID = UUID()
        buffer.append(workflowID: ruleID, name: "同名规则", at: start)
        buffer.append(workflowID: ruleID, name: "后来改名", at: start.advanced(by: .seconds(1)))
        buffer.append(workflowID: UUID(), name: "同名规则", at: start.advanced(by: .seconds(2)))
        buffer.append(workflowID: UUID(), name: "第二轮", at: start.advanced(by: .seconds(9)))
        let pending = buffer.drain()
        #expect(pending.count == 2)
        #expect(pending.first?.names == ["同名规则", "同名规则"])
        #expect(pending.last?.names == ["第二轮"])
        #expect(pending.first?.id != pending.last?.id)
    }

    @Test func disabledAndStoppedSessionsDiscardHitsAndInvalidateOldDelivery() throws {
        let buffer = RuleHitNotificationBuffer(), id = UUID()
        buffer.append(workflowID: id, name: "关闭")
        #expect(buffer.drain().isEmpty)
        buffer.startSession(enabled: true)
        buffer.append(workflowID: id, name: "第一轮")
        let old = try #require(buffer.drain().first)
        buffer.append(workflowID: UUID(), name: "等待发送")
        buffer.stopSession()
        #expect(!buffer.isCurrent(old))
        #expect(buffer.drain().isEmpty)
        buffer.append(workflowID: id, name: "已停止")
        #expect(buffer.drain().isEmpty)
        buffer.startSession(enabled: true)
        buffer.append(workflowID: id, name: "新会话")
        let next = try #require(buffer.drain().first)
        #expect(next.sessionID != old.sessionID)
        #expect(next.id != old.id)
        #expect(buffer.isCurrent(next))
        buffer.startSession(enabled: false)
        buffer.append(workflowID: id, name: "未启用")
        #expect(buffer.drain().isEmpty)
    }
}
