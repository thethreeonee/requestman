import Foundation
import Testing
@testable import RequestmanCore

struct WorkflowMatchTestTests {
    @Test func diagnosticsUseLiveGroupLogicIncludingAnyBranches() {
        var workflow = RequestWorkflow()
        workflow.matchConditions = WorkflowMatchGroup(mode: .any, conditions: [
            .init(field: .host, operation: .equals, value: "api.test"),
            .init(field: .header, operation: .equals, name: "X-Env", value: "staging")])
        for url in ["https://api.test/", "https://other.test/"] {
            for headers: [HTTPField] in [[], [.init("X-Env", "staging")], [.init("X-Env", "prod")]] {
                let result = WorkflowMatchTest.evaluate(workflow, method: "GET", url: url, headers: headers)
                #expect(result.error == nil)
                #expect(result.matched == workflow.matches(method: "GET", url: url, headers: headers))
                #expect(result.conditions.count == 3)
            }
        }
        let result = WorkflowMatchTest.evaluate(workflow, method: "GET", url: "https://api.test/", headers: [])
        #expect(result.matched && result.conditions.last?.matched == false)
        #expect(result.conditions.last?.detail.contains("字段不存在") == true)
    }
    @Test func errorsAreDistinctFromNonMatchesAndDisabledRulesCanBeTested() {
        var workflow = RequestWorkflow()
        workflow.matchConditions.conditions = [.init(field: .url, operation: .regex, value: "[")]
        let invalid = WorkflowMatchTest.evaluate(workflow, method: "GET", url: "https://example.com", headers: [])
        #expect(invalid.error != nil && invalid.conditions.isEmpty)
        workflow.matchConditions.conditions = [.init(field: .url, operation: .contains, value: "example")]
        #expect(WorkflowMatchTest.evaluate(workflow, method: "GET", url: "not a URL", headers: []).error != nil)
        workflow.enabled = false
        #expect(WorkflowMatchTest.evaluate(workflow, method: "GET", url: "https://example.com", headers: []).matched)
        workflow.matchConditions.conditions.append(.init(field: .header, operation: .exists, name: "Invalid Header"))
        #expect(WorkflowMatchTest.validationError(for: workflow) != nil)
    }
    @Test func unicodeRangeAndZeroLengthMatchesRemainValid() {
        let text = "https://example.com/订单/123"
        let range = WorkflowMatcher.matchingRange(in: text, rule: .regex, pattern: "订单/[0-9]+$")!
        #expect((text as NSString).substring(with: range) == "订单/123")
        #expect(WorkflowMatcher.matchingRange(in: text, rule: .regex, pattern: "^")?.length == 0)
    }
}
