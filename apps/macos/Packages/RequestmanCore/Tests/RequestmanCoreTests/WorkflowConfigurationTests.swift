import Foundation
import Testing
@testable import RequestmanCore

struct WorkflowConfigurationTests {
    @Test func targetsAndFourRules() {
        var flow = RequestWorkflow()
        flow.matchConditions.conditions[0].field = .host
        flow.matchConditions.conditions[0].operation = .equals; flow.matchConditions.conditions[0].value = "API.Example.COM"
        #expect(flow.matches(method: "GET", url: "https://api.example.com:8443/path?x=1"))
        #expect(!flow.matches(method: "GET", url: "https://api.example.com.attacker.test/"))
        #expect(!flow.matches(method: "GET", url: "https://other.test/api.example.com"))
        flow.matchConditions.conditions[0].operation = .wildcard; flow.matchConditions.conditions[0].value = "*.example.com"
        #expect(flow.matches(method: "GET", url: "https://api.example.com/"))
        #expect(!flow.matches(method: "GET", url: "https://example.com/"))
        flow.matchConditions.conditions[0].operation = .contains; flow.matchConditions.conditions[0].value = "EXAMPLE"
        #expect(flow.matches(method: "GET", url: "https://api.example.com/"))
        flow.matchConditions.conditions[0].operation = .regex; flow.matchConditions.conditions[0].value = #"^api\d+\.example\.com$"#
        #expect(flow.matches(method: "GET", url: "https://api2.example.com:444/path"))
        #expect(!flow.matches(method: "GET", url: "https://api.example.com/"))
        flow.matchConditions.conditions[0].value = "["
        #expect(!flow.matches(method: "GET", url: "https://api.example.com/"))
        flow.matchConditions.conditions[0].field = .url; flow.matchConditions.conditions[0].operation = .wildcard; flow.matchConditions.conditions[0].value = "https://example.com/a?/*"
        #expect(flow.matches(method: "GET", url: "https://example.com/ab/test"))
        #expect(!flow.matches(method: "GET", url: "https://example.com/abc/test"))
        flow.matchConditions.conditions[0].operation = .equals; flow.matchConditions.conditions[0].value = "https://example.com/Test"
        #expect(!flow.matches(method: "GET", url: "https://example.com/test"))
        flow.matchConditions.conditions[0].operation = .contains; flow.matchConditions.conditions[0].value = "/Test"
        #expect(flow.matches(method: "GET", url: "https://example.com/Test?id=1"))
        flow.matchConditions.conditions[0].value = ""
        #expect(!flow.matches(method: "GET", url: "https://example.com/"))
    }

    @Test func conditionGroupRoundTrip() throws {
        var flow = RequestWorkflow()
        flow.matchConditions.groups = [WorkflowMatchGroup(mode: .any, conditions: [MatchCondition(field: .host, operation: .equals, value: "api.test")])]
        let encoded = try JSONEncoder().encode(flow)
        #expect(try JSONDecoder().decode(RequestWorkflow.self, from: encoded) == flow)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("matchPattern"))
    }

}

@Suite(.serialized)
struct WorkflowScriptTests {
    private func run(_ source: String, response: Bool = false, body: String? = nil, timeout: Int = 1000) throws -> HTTPMessageDraft {
        var draft = HTTPMessageDraft(method: "POST", url: "https://example.com/", headers: [HTTPField("Set-Cookie", "a=1"), HTTPField("Set-Cookie", "b=2")])
        draft.bodyText = body
        return try WorkflowScript.run(source: source, draft: draft, response: response, request: draft, environment: ["token": "literal {{env.other}}"], timeoutMilliseconds: timeout)
    }
    @Test func requestResponseAndHeaderArrays() throws {
        let request = try run("request.method = 'PATCH'; request.headers.push({ name: 'Authorization', value: env.token }); return request;")
        #expect(request.method == "PATCH")
        #expect(request.headers.filter { $0.name == "Set-Cookie" }.count == 2)
        #expect(request.headers.last?.value == "literal {{env.other}}")
        let response = try run("const body = JSON.parse(response.body); body.ok = true; response.body = JSON.stringify(body); response.status = 201; return response;", response: true, body: "{}")
        #expect(response.replacementBody == #"{"ok":true}"#)
        #expect(response.status == 201)
    }
    @Test func nullEmptyAndInvalidResults() throws {
        #expect(try run("request.body = null; return request;", body: "unchanged").replacementBody == nil)
        #expect(try run("request.body = ''; return request;", body: "remove").replacementBody == "")
        for source in ["return 1;", "throw new Error('broken');", "return Promise.resolve(request);", "request.headers = {}; return request;",
                       "request.body = {}; return request;", "request.headers.push({name:'Bad Name',value:'x'}); return request;",
                       "request.headers.push({name:'Content-Length',value:'123'}); return request;", "request.url = 'file:///tmp/test'; return request;"] {
            #expect(throws: (any Error).self) { try run(source) }
        }
    }
    @Test func timeoutTerminatesAndNextScriptWorks() throws {
        let clock = ContinuousClock.now
        #expect(throws: (any Error).self) { try run("while (true) {}", timeout: 150) }
        #expect(clock.duration(to: .now) < .seconds(3))
        #expect(try run("return request;").method == "POST")
    }
    @Test func largeBodiesAndCancellation() throws {
        let large = String(repeating: "x", count: 2 * 1024 * 1024)
        let result = try run("request.body += '!'; return request;", body: large)
        #expect(result.replacementBody?.utf8.count == large.utf8.count + 1)
        let control = ScriptExecutionControl()
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) { control.cancel() }
        let start = ContinuousClock.now
        #expect(throws: (any Error).self) {
            try WorkflowScript.run(source: "while (true) {}", draft: HTTPMessageDraft(method: "GET", url: "https://example.com"),
                                   response: false, request: nil, environment: [:], timeoutMilliseconds: 5000, control: control)
        }
        #expect(start.duration(to: .now) < .seconds(2))
    }
    @Test func templateSyntaxIsNotExpandedAndInactiveRequestIsFrozen() throws {
        let request = try run("request.body = '{{env.token}}'; return request;")
        #expect(request.replacementBody == "{{env.token}}")
        #expect(throws: (any Error).self) { try run("request.method = 'DELETE'; return response;", response: true) }
    }
}
