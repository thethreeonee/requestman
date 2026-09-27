import Foundation
import Testing
@testable import RequestmanCore

struct HeaderMatchingTests {
    private var flow: RequestWorkflow {
        var flow = RequestWorkflow()
        flow.matchConditions = WorkflowMatchGroup(conditions: [
            MatchCondition(field: .url, operation: .equals, value: "https://example.test/"),
            MatchCondition(field: .header, operation: .equals, name: "X-Environment", value: "staging")])
        return flow
    }
    @Test func namesIgnoreCaseValuesDoNotAndMissingHeadersNeverMatch() {
        let headers = [HTTPField("x-environment", "other"), HTTPField("X-ENVIRONMENT", "staging")]
        #expect(flow.matches(method: "GET", url: "https://example.test/", headers: headers))
        #expect(!flow.matches(method: "GET", url: "https://example.test/", headers: [.init("X-Environment", "Staging")]))
        #expect(!flow.matches(method: "GET", url: "https://example.test/"))
        var wildcard = flow; wildcard.matchConditions.conditions[1].operation = .wildcard; wildcard.matchConditions.conditions[1].value = "*"
        #expect(!wildcard.matches(method: "GET", url: "https://example.test/"))
        #expect(wildcard.matches(method: "GET", url: "https://example.test/", headers: [.init("X-Environment", "")]))
    }
    @Test func allOperatorsAndMethodAndDisabledConditions() {
        for (rule, pattern) in [(MatchOperator.equals, "staging-eu"), (.contains, "aging"), (.wildcard, "staging-??"), (.regex, "^staging-[a-z]{2}$")] {
            var candidate = flow
            candidate.matchConditions.conditions[1].operation = rule; candidate.matchConditions.conditions[1].value = pattern
            candidate.matchConditions.conditions.append(.init(field: .method, operation: .equals, value: "POST"))
            #expect(candidate.matches(method: "post", url: "https://example.test/", headers: [.init("X-Environment", "staging-eu")]))
            #expect(!candidate.matches(method: "GET", url: "https://example.test/", headers: [.init("X-Environment", "staging-eu")]))
            candidate.enabled = false
            #expect(!candidate.matches(method: "POST", url: "https://example.test/", headers: [.init("X-Environment", "staging-eu")]))
        }
    }
    @Test func invalidNamesAndNegationRequirePresence() {
        for name in ["", "Bad Name", "X-Env\r\n"] {
            var invalid = flow; invalid.matchConditions.conditions[1].name = name
            #expect(!invalid.matches(method: "GET", url: "https://example.test/", headers: [.init("X-Environment", "staging")]))
        }
        var negative = MatchCondition(field: .header, operation: .notEquals, name: "X-Environment", value: "prod")
        #expect(!negative.matches(method: "GET", url: "https://example.test/", headers: []))
        #expect(!negative.matches(method: "GET", url: "https://example.test/", headers: [.init("x-environment", "staging"), .init("X-Environment", "prod")]))
        #expect(negative.matches(method: "GET", url: "https://example.test/", headers: [.init("x-environment", "staging")]))
        negative.operation = .notExists
        #expect(negative.matches(method: "GET", url: "https://example.test/", headers: []))
    }
    @Test func multipleHeadersAndGroupsRoundTrip() throws {
        var candidate = flow
        candidate.matchConditions.conditions.append(.init(field: .header, operation: .exists, name: "Authorization"))
        #expect(!candidate.matches(method: "GET", url: "https://example.test/", headers: [.init("X-Environment", "staging")]))
        #expect(candidate.matches(method: "GET", url: "https://example.test/", headers: [.init("X-Environment", "staging"), .init("Authorization", "Bearer test")]))
        #expect(try JSONDecoder().decode(RequestWorkflow.self, from: JSONEncoder().encode(candidate)) == candidate)
    }
}
