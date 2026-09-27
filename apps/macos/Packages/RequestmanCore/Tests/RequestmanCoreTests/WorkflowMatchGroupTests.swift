import Foundation
import Testing
@testable import RequestmanCore

struct WorkflowMatchGroupTests {
    @Test func addressPartsQueryCookieAndContentType() {
        let url = "https://api.example.com:8443/v1/orders/a%2Fb?preview=true&tag=one&tag=two&empty=&flag&name=%E4%B8%AD%E6%96%87&plus=a+b"
        let headers: [HTTPField] = [.init("Cookie", "debug=1; session=a=b; empty="), .init("Content-Type", "Application/JSON; charset=utf-8")]
        let conditions: [MatchCondition] = [
            .init(field: .method, operation: .oneOf, value: "POST, PUT"),
            .init(field: .path, operation: .beginsWith, value: "/v1/orders/"),
            .init(field: .scheme, operation: .equals, value: "https"),
            .init(field: .port, operation: .equals, value: "8443"),
            .init(field: .query, operation: .equals, name: "tag", value: "two"),
            .init(field: .query, operation: .isEmpty, name: "flag"),
            .init(field: .query, operation: .equals, name: "name", value: "中文"),
            .init(field: .query, operation: .equals, name: "plus", value: "a+b"),
            .init(field: .cookie, operation: .equals, name: "session", value: "a=b"),
            .init(field: .cookie, operation: .isEmpty, name: "empty"),
            .init(field: .contentType, operation: .equals, value: "application/json")]
        for item in conditions { #expect(item.matches(method: "post", url: url, headers: headers), "\(item.summary)") }
        #expect(MatchCondition(field: .port, operation: .equals, value: "443").matches(method: "GET", url: "https://example.com/", headers: []))
        #expect(!MatchCondition(field: .query, operation: .notEquals, name: "tag", value: "one").matches(method: "GET", url: url, headers: []))
        #expect(!MatchCondition(field: .query, operation: .isEmpty, name: "missing").matches(method: "GET", url: url, headers: []))
    }
    @Test func domainBoundaryInvalidGroupsAndDisabledDrafts() {
        let domain = MatchCondition(field: .host, operation: .domainAndSubdomains, value: "example.com")
        for host in ["example.com", "API.example.com", "x.y.example.com"] {
            #expect(domain.matches(method: "GET", url: "https://\(host)/", headers: []))
        }
        for host in ["badexample.com", "example.com.attacker.test"] {
            #expect(!domain.matches(method: "GET", url: "https://\(host)/", headers: []))
        }
        var group = WorkflowMatchGroup(mode: .any, conditions: [domain, .init(field: .url, operation: .regex, value: "[")])
        #expect(!group.matches(method: "GET", url: "https://example.com/", headers: []))
        group.conditions[1].enabled = false
        #expect(group.matches(method: "GET", url: "https://example.com/", headers: []))
        group.conditions[0].enabled = false
        #expect(!group.matches(method: "GET", url: "https://example.com/", headers: []))
        #expect(!WorkflowMatchGroup(mode: .all).matches(method: "GET", url: "https://example.com/", headers: []))
    }
    @Test func nestedAnyAndFirstWorkflowSelection() throws {
        var flow = RequestWorkflow()
        flow.matchConditions = WorkflowMatchGroup(conditions: [.init(field: .path, operation: .beginsWith, value: "/orders")], groups: [
            WorkflowMatchGroup(mode: .any, conditions: [.init(field: .host, operation: .equals, value: "api.test"), .init(field: .host, operation: .equals, value: "staging.test")])])
        #expect(flow.matches(method: "GET", url: "https://api.test/orders/1"))
        #expect(flow.matches(method: "GET", url: "https://staging.test/orders/1"))
        #expect(!flow.matches(method: "GET", url: "https://staging.test/users"))
        #expect(!flow.matches(method: "GET", url: "https://other.test/orders/1"))
        let duplicate = flow.duplicated()
        #expect(flow.matchConditions.id != duplicate.matchConditions.id)
        #expect(flow.matchConditions.groups[0].conditions[0].id != duplicate.matchConditions.groups[0].conditions[0].id)
        var project = WorkflowProject(); project.workflows = [flow, duplicate]
        var document = WorkspaceDocument(); document.projects = [project]
        #expect(WorkflowEngine.match(document, method: "GET", url: "https://api.test/orders/1")?.workflow.id == flow.id)
        document.projects[0].workflows[0].enabled = false
        #expect(WorkflowEngine.match(document, method: "GET", url: "https://api.test/orders/1")?.workflow.id == duplicate.id)
        let decoded = try JSONDecoder().decode(WorkspaceDocument.self, from: JSONEncoder().encode(document))
        #expect(decoded == document)
        let archive = try WorkspaceArchive(project: project).encoded()
        let imported = try WorkspaceArchive.decode(archive).merging(into: WorkspaceDocument())
        #expect(imported.projects[0].workflows[0].matches(method: "GET", url: "https://staging.test/orders/1"))
    }
}
