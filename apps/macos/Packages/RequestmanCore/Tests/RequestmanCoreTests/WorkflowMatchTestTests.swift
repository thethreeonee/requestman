import Foundation
import Testing
@testable import RequestmanCore

struct WorkflowMatchTestTests {
    @Test func matchesLiveRulesAcrossTargetsAndOperators() {
        for target in WorkflowMatchTarget.allCases {
            for rule in WorkflowMatchRule.allCases {
                var workflow = RequestWorkflow()
                workflow.matchTarget = target; workflow.matchRule = rule; workflow.method = "GET"
                let host = target == .host
                switch rule {
                case .equals: workflow.matchPattern = host ? "API.EXAMPLE.COM" : "https://api.example.com/v1/orders/123"
                case .contains: workflow.matchPattern = host ? "EXAMPLE" : "/orders/"
                case .wildcard: workflow.matchPattern = host ? "*.EXAMPLE.COM" : "https://*/v1/orders/???"
                case .regex: workflow.matchPattern = host ? "^API\\.EXAMPLE\\.COM$" : "/v1/orders/[0-9]+$"
                }
                for method in ["GET", "get", "POST"] {
                    for url in ["https://api.example.com/v1/orders/123", "https://other.test/v1/users/1"] {
                        let result = WorkflowMatchTest.evaluate(workflow, method: method, url: url, headers: [])
                        #expect(result.error == nil)
                        #expect(result.matched == workflow.matches(method: method, url: url))
                    }
                }
            }
        }
    }

    @Test func highlightsRegexAndExplainsHeaderMismatch() throws {
        var workflow = RequestWorkflow()
        workflow.matchRule = .regex; workflow.matchPattern = "/v1/orders/[0-9]+$"
        workflow.matchHeaderEnabled = true; workflow.matchHeaderName = "X-Environment"
        workflow.matchHeaderPattern = "staging"
        let url = "https://api.example.com/v1/orders/123"
        let result = WorkflowMatchTest.evaluate(workflow, method: "GET", url: url,
                                                headers: [.init("x-environment", "production")])
        #expect(!result.matched && result.error == nil)
        #expect(result.conditions.map(\.matched) == [true, true, false])
        let range = try #require(result.conditions[1].highlight)
        #expect((url as NSString).substring(with: range) == "/v1/orders/123")
        #expect(result.conditions[2].detail.contains("production"))
        let missing = WorkflowMatchTest.evaluate(workflow, method: "GET", url: url, headers: [])
        #expect(missing.conditions[2].detail.contains("缺少此 Header"))
        let duplicate = WorkflowMatchTest.evaluate(workflow, method: "GET", url: url,
            headers: [.init("X-Environment", "production"), .init("x-environment", "staging")])
        #expect(duplicate.matched)
    }

    @Test func errorsAreDistinctFromNonMatchesAndDisabledRulesCanBeTested() {
        var workflow = RequestWorkflow()
        workflow.matchRule = .regex; workflow.matchPattern = "["
        let invalid = WorkflowMatchTest.evaluate(workflow, method: "GET", url: "https://example.com", headers: [])
        #expect(invalid.error != nil && invalid.conditions.isEmpty)
        workflow.matchRule = .contains; workflow.matchPattern = "example"
        #expect(WorkflowMatchTest.evaluate(workflow, method: "GET", url: "not a URL", headers: []).error != nil)
        workflow.enabled = false
        #expect(WorkflowMatchTest.evaluate(workflow, method: "GET", url: "https://example.com", headers: []).matched)
        workflow.matchHeaderEnabled = true; workflow.matchHeaderName = "Invalid Header"
        #expect(WorkflowMatchTest.validationError(for: workflow) != nil)
    }

    @Test func unicodeRangeAndZeroLengthMatchesRemainValid() {
        let text = "https://example.com/订单/123"
        let range = WorkflowMatcher.matchingRange(in: text, rule: .regex, pattern: "订单/[0-9]+$")!
        #expect((text as NSString).substring(with: range) == "订单/123")
        #expect(WorkflowMatcher.matchingRange(in: text, rule: .regex, pattern: "^")?.length == 0)
    }
}
