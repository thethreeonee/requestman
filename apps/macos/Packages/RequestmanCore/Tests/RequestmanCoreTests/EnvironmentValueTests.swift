import Foundation
import Testing
@testable import RequestmanCore

@Suite(.serialized)
struct EnvironmentValueTests {
    @Test func legacyAndTypedRoundTrip() throws {
        let data = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "name": "legacy", "value": "123"])
        let legacy = try JSONDecoder().decode(NamedValue.self, from: data)
        #expect(legacy.type == .string)
        var environment = WorkspaceEnvironment(name: "typed")
        environment.variables = [legacy, NamedValue(name: "count", value: "123", type: .number),
            NamedValue(name: "enabled", value: "true", type: .boolean),
            NamedValue(name: "items", value: "[1, null, false]", type: .array),
            NamedValue(name: "config", value: #"{"nested":{"ready":true}}"#, type: .object)]
        #expect(try JSONDecoder().decode(WorkspaceEnvironment.self, from: JSONEncoder().encode(environment)) == environment)
        #expect(try WorkflowEngine.resolve("{{$env.count}}:{{$env.enabled}}:{{$env.items}}", environment: environment.values,
                                           id: UUID(), date: Date()) == "123:true:[1, null, false]")
    }

    @Test func rejectsWrongTypesAndMalformedJSON() {
        for value in ["", "true", "null", "NaN", "Infinity", "01", "1e999", "\"123\""] { #expect(!EnvironmentValueType.number.accepts(value)) }
        #expect(EnvironmentValueType.number.accepts("-1.25e2"))
        for value in ["1", "TRUE", "null", "\"true\""] { #expect(!EnvironmentValueType.boolean.accepts(value)) }
        #expect(EnvironmentValueType.boolean.accepts(" false "))
        #expect(!EnvironmentValueType.array.accepts("{}"))
        #expect(!EnvironmentValueType.object.accepts("[]"))
        #expect(!EnvironmentValueType.object.accepts("{broken}"))
        #expect(EnvironmentValueType.string.accepts("anything {{literal}}"))
    }

    @Test func scriptReceivesTypesInBothPhases() async throws {
        var environment = WorkspaceEnvironment(name: "typed")
        environment.variables = [NamedValue(name: "text", value: "123"), NamedValue(name: "count", value: "2.5", type: .number),
            NamedValue(name: "enabled", value: "false", type: .boolean), NamedValue(name: "items", value: "[1,null]", type: .array),
            NamedValue(name: "config", value: #"{"enabled":true}"#, type: .object)]
        var step = ModificationStep(kind: .script)
        step.value = """
        if (typeof env.text !== 'string' || env.count + 1 !== 3.5 || env.enabled !== false ||
            !Array.isArray(env.items) || env.items[1] !== null || env.config.enabled !== true ||
            !Object.isFrozen(env.config)) throw new Error('Wrong environment type');
        const message = response || request;
        message.body = 'typed'; return message;
        """
        var request = HTTPMessageDraft(method: "GET", url: "https://example.com/")
        _ = try WorkflowEngine.apply([step], response: false, to: &request, environment: environment.values,
                                     id: UUID(), date: Date(), environmentTypes: environment.valueTypes)
        #expect(request.replacementBody == "typed")
        var response = HTTPMessageDraft(method: "GET", url: "https://example.com/")
        _ = try await WorkflowEngine.applyAsync([step], response: true, to: &response, environment: environment.values,
                                               id: UUID(), date: Date(), request: request, environmentTypes: environment.valueTypes)
        #expect(response.replacementBody == "typed")
        #expect(throws: (any Error).self) {
            try WorkflowScript.run(source: "return request;", draft: request, response: false, request: nil,
                environment: ["bad": "true"], timeoutMilliseconds: 1000, environmentTypes: ["bad": .number])
        }
    }
}
