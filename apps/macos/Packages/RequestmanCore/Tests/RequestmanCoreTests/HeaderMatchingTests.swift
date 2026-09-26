import Foundation
import Testing
@testable import RequestmanCore

struct HeaderMatchingTests {
    private var flow: RequestWorkflow {
        var flow = RequestWorkflow()
        flow.matchTarget = .url; flow.matchRule = .equals; flow.matchPattern = "https://example.test/"
        flow.matchHeaderEnabled = true; flow.matchHeaderName = "X-Environment"
        flow.matchHeaderRule = .equals; flow.matchHeaderPattern = "staging"
        return flow
    }

    @Test func namesIgnoreCaseValuesDoNotAndMissingHeadersNeverMatch() {
        let headers = [HTTPField("x-environment", "other"), HTTPField("X-ENVIRONMENT", "staging")]
        #expect(flow.matches(method: "GET", url: "https://example.test/", headers: headers))
        #expect(!flow.matches(method: "GET", url: "https://example.test/", headers: [HTTPField("X-Environment", "Staging")]))
        #expect(!flow.matches(method: "GET", url: "https://example.test/"))
        #expect(!flow.matches(method: "GET", url: "https://example.test/", headers: [HTTPField("Other", "staging")]))
        var wildcard = flow; wildcard.matchHeaderRule = .wildcard; wildcard.matchHeaderPattern = "*"
        #expect(!wildcard.matches(method: "GET", url: "https://example.test/"))
        #expect(wildcard.matches(method: "GET", url: "https://example.test/", headers: [HTTPField("X-Environment", "")]))
    }

    @Test func allOperatorsValidateAndPreserveMethodAndEnabledConditions() {
        let headers = [HTTPField("X-Environment", "staging-eu")]
        for (rule, pattern) in [(WorkflowMatchRule.equals, "staging-eu"), (.contains, "aging"), (.wildcard, "staging-??"), (.regex, "^staging-[a-z]{2}$")] {
            var candidate = flow; candidate.matchHeaderRule = rule; candidate.matchHeaderPattern = pattern; candidate.method = "POST"
            #expect(candidate.matches(method: "post", url: "https://example.test/", headers: headers))
            #expect(!candidate.matches(method: "GET", url: "https://example.test/", headers: headers))
            candidate.enabled = false
            #expect(!candidate.matches(method: "POST", url: "https://example.test/", headers: headers))
        }
        for name in ["", "Bad Name", "X-Env\r\n"] {
            var invalid = flow; invalid.matchHeaderName = name
            #expect(!invalid.matches(method: "GET", url: "https://example.test/", headers: headers))
        }
        var invalid = flow; invalid.matchHeaderRule = .regex; invalid.matchHeaderPattern = "["
        #expect(!invalid.matches(method: "GET", url: "https://example.test/", headers: headers))
        invalid.matchHeaderRule = .equals; invalid.matchHeaderPattern = ""
        #expect(!invalid.matches(method: "GET", url: "https://example.test/", headers: headers))
    }

    @Test func addressAndHeaderMustBothMatchAndCanBeDisabledIndependently() {
        let matching = [HTTPField("X-Environment", "staging")]
        for target in WorkflowMatchTarget.allCases {
            var candidate = flow; candidate.matchTarget = target
            candidate.matchPattern = target == .url ? "https://example.test/" : "example.test"
            #expect(candidate.matches(method: "GET", url: "https://example.test/", headers: matching))
            #expect(!candidate.matches(method: "GET", url: "https://other.test/", headers: matching))
            #expect(!candidate.matches(method: "GET", url: "https://example.test/", headers: [HTTPField("X-Environment", "production")]))
            #expect(!candidate.matches(method: "GET", url: "https://example.test/"))
            candidate.matchHeaderEnabled = false
            #expect(candidate.matches(method: "GET", url: "https://example.test/"))
            #expect(!candidate.matches(method: "GET", url: "https://other.test/", headers: matching))
            candidate.matchHeaderEnabled = true
            #expect(!candidate.matches(method: "GET", url: "https://example.test/"))
        }
    }

    @Test func previousHeaderOnlyConfigurationRetainsItsCondition() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(flow)) as? [String: Any])
        for key in ["matchHeaderEnabled", "matchHeaderRule", "matchHeaderPattern"] { object.removeValue(forKey: key) }
        object["matchTarget"] = "header"; object["matchRule"] = "equals"; object["matchPattern"] = "staging"
        let decoded = try JSONDecoder().decode(RequestWorkflow.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.matchTarget == .url && decoded.matchRule == .wildcard && decoded.matchPattern == "*")
        #expect(decoded.matchHeaderEnabled && decoded.matchHeaderRule == .equals && decoded.matchHeaderPattern == "staging")
        #expect(!decoded.matches(method: "GET", url: "https://other.test/"))
        #expect(decoded.matches(method: "GET", url: "https://other.test/", headers: [HTTPField("X-Environment", "staging")]))
    }

    @Test func selectionUsesHeadersAndFirstMatchWhileOlderDocumentsStillDecode() throws {
        var project = WorkflowProject(); project.workflows = [flow, flow]
        var document = WorkspaceDocument(); document.projects = [project]
        #expect(WorkflowEngine.match(document, method: "GET", url: "https://example.test/") == nil)
        let match = WorkflowEngine.match(document, method: "GET", url: "https://example.test/", headers: [HTTPField("X-Environment", "staging")])
        #expect(match?.workflow.id == project.workflows[0].id)
        let encoded = try JSONEncoder().encode(document)
        #expect(try JSONDecoder().decode(WorkspaceDocument.self, from: encoded) == document)

        let existing = RequestWorkflow()
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(existing)) as? [String: Any])
        for key in ["matchHeaderName", "matchHeaderEnabled", "matchHeaderRule", "matchHeaderPattern"] { object.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(RequestWorkflow.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded == existing && decoded.matchHeaderName.isEmpty)
    }
}
