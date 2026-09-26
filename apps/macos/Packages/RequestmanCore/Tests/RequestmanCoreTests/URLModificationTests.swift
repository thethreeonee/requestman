import Foundation
import Testing
@testable import RequestmanCore

struct URLModificationTests {
    private func apply(_ steps: [ModificationStep], url: String, environment: [String: String] = [:]) throws -> HTTPMessageDraft {
        var draft = HTTPMessageDraft(method: "GET", url: url)
        _ = try WorkflowEngine.apply(steps, response: false, to: &draft, environment: environment, id: UUID(), date: Date())
        return draft
    }

    @Test func queryPreservesUnrelatedBytesAndReplacesExactDuplicateNames() throws {
        var step = ModificationStep(kind: .setQueryParameter)
        step.name = "key"; step.value = "中文 &+=/#?"
        let original = "https://example.test/a%2fb?keep=%2f+%20&key=old&Key=upper&%6Bey=other&flag&&tail="
        let result = try apply([step], url: original)
        #expect(result.url == "https://example.test/a%2fb?keep=%2f+%20&key=%E4%B8%AD%E6%96%87%20%26%2B%3D%2F%23%3F&Key=upper&flag&&tail=")
        let items = URLComponents(string: result.url)?.queryItems ?? []
        #expect(items.filter { $0.name == "key" }.map(\.value) == [step.value])
    }

    @Test func queryAddsEmptyValuesAndResolvesNamesAndValues() throws {
        var step = ModificationStep(kind: .setQueryParameter)
        step.name = "{{env.name}}"; step.value = "{{env.value}}"
        let env = ["name": "a+b", "value": ""]
        for url in ["https://example.test/", "https://example.test/?"] {
            #expect(try apply([step], url: url, environment: env).url == "https://example.test/?a%2Bb=")
        }
        #expect(try apply([step], url: "https://example.test/?a+b=old", environment: env).url == "https://example.test/?a%2Bb=")
    }

    @Test func mixedQueryOperationsPreserveOrderAndUntouchedBytes() throws {
        var step = ModificationStep(kind: .setQueryParameter)
        step.queryParameterEntries = [
            QueryParameterEntry(name: "debug", value: "true"),
            QueryParameterEntry(operation: .modify, name: "page", value: "{{$env.page}}"),
            QueryParameterEntry(operation: .remove, name: "utm_source", value: "{{$env.unused}}"),
            QueryParameterEntry(name: "debug", value: "{{$env.unused}}"),
            QueryParameterEntry(operation: .modify, name: "absent", value: "{{$env.unused}}")
        ]
        let original = "https://example.test/a%2fb?keep=%2f+%20&page=1&%70age=3&Page=4&utm_source=a&utm_source=b&flag&&tail="
        #expect(try apply([step], url: original, environment: ["page": "中文 &+"]).url ==
            "https://example.test/a%2fb?keep=%2f+%20&page=%E4%B8%AD%E6%96%87%20%26%2B&%70age=%E4%B8%AD%E6%96%87%20%26%2B&Page=4&flag&&tail=&debug=true")
        let decoded = try JSONDecoder().decode(ModificationStep.self, from: JSONEncoder().encode(step))
        #expect(decoded == step)
        step.queryParameterEntries = [QueryParameterEntry(name: "x", value: "1"), QueryParameterEntry(operation: .remove, name: "x"), QueryParameterEntry(name: "x", value: "")]
        #expect(try apply([step], url: "https://example.test/").url == "https://example.test/?x=")
    }

    @Test func queryRemovalAndEmptyListAreNoOpsWhenUnmatched() throws {
        var step = ModificationStep(kind: .setQueryParameter)
        step.queryParameterEntries = [QueryParameterEntry(operation: .remove, name: "x", value: "{{$env.missing}}")]
        #expect(try apply([step], url: "https://example.test/?x=1&%78=2").url == "https://example.test/")
        for url in ["https://example.test/", "https://example.test/?", "https://example.test/?keep=%2f&&flag"] {
            #expect(try apply([step], url: url).url == url)
        }
        step.queryParameterEntries = []
        step.value = "{{$env.missing}}"
        #expect(try apply([step], url: "https://example.test/?x=1").url == "https://example.test/?x=1")
    }

    @Test func queryListValidationIsAtomicAndLegacyEditingKeepsSemantics() throws {
        var step = ModificationStep(kind: .setQueryParameter)
        step.name = "x"; step.value = "new"
        let legacy = try JSONDecoder().decode(ModificationStep.self, from: JSONEncoder().encode(step))
        #expect(legacy.queryParameters == nil && legacy.queryParameterEntries[0].operation == nil)
        step.queryParameterEntries = legacy.queryParameterEntries
        #expect(try apply([step], url: "https://example.test/?x=1&x=2").url == "https://example.test/?x=new")
        #expect(try apply([step], url: "https://example.test/").url == "https://example.test/?x=new")
        step.queryParameterEntries = [QueryParameterEntry(name: "first", value: "1"), QueryParameterEntry(operation: .modify, name: "x", value: "{{$env.missing}}")]
        var draft = HTTPMessageDraft(method: "GET", url: "https://example.test/?x=old")
        var applied: [ModificationKind] = []
        #expect(throws: WorkflowError.self) {
            try WorkflowEngine.apply([step], response: false, to: &draft, environment: [:], id: UUID(), date: Date(), onApplied: { applied.append($0) })
        }
        #expect(draft.url == "https://example.test/?x=old" && applied.isEmpty)
    }

    @Test(arguments: [WorkflowMatchRule.equals, .contains, .wildcard, .regex])
    func queryNameRulesModifyAndRemoveWithoutRenaming(_ rule: WorkflowMatchRule) throws {
        let patterns: [WorkflowMatchRule: String] = [.equals: "key", .contains: "key", .wildcard: "key*", .regex: "^(prefix_key|key_tail)$"]
        let names = ["prefix_key", "key", "%6Bey", "key_tail", "Key", "literal"]
        let matching: [WorkflowMatchRule: Set<Int>] = [.equals: [1, 2], .contains: [0, 1, 2, 3], .wildcard: [1, 2, 3], .regex: [0, 3]]
        let query = names.map { $0 + "=key" }
        let base = "https://example.test/?"
        let tail = "&flag&&keep=%2f+%20"
        for operation in [QueryParameterOperation.modify, .remove] {
            var step = ModificationStep(kind: .setQueryParameter)
            step.queryParameterEntries = [QueryParameterEntry(operation: operation, name: "{{$env.pattern}}", value: "new +", matchRule: rule)]
            let expected = query.enumerated().compactMap { index, pair -> String? in
                guard matching[rule]!.contains(index) else { return pair }
                return operation == .remove ? nil : names[index] + "=new%20%2B"
            }.joined(separator: "&")
            #expect(try apply([step], url: base + query.joined(separator: "&") + tail, environment: ["pattern": patterns[rule]!]).url == base + expected + tail)
            let decoded = try JSONDecoder().decode(ModificationStep.self, from: JSONEncoder().encode(step))
            #expect(decoded == step)
            step.queryParameterEntries[0].name = "not_matched"
            step.queryParameterEntries[0].value = "{{$env.unused}}"
            #expect(try apply([step], url: base + "flag").url == base + "flag")
        }
    }

    @Test func invalidQueryRegexIsAtomicAndAdditionUsesLiteralNames() throws {
        var step = ModificationStep(kind: .setQueryParameter)
        for operation in [QueryParameterOperation.modify, .remove] {
            step.queryParameterEntries = [QueryParameterEntry(name: "first", value: "new"), QueryParameterEntry(operation: operation, name: "[", matchRule: .regex)]
            var draft = HTTPMessageDraft(method: "GET", url: "https://example.test/?key=old")
            #expect(throws: WorkflowError.self) {
                try WorkflowEngine.apply([step], response: false, to: &draft, environment: [:], id: UUID(), date: Date())
            }
            #expect(draft.url == "https://example.test/?key=old")
        }
        step.queryParameterEntries = [QueryParameterEntry(name: "[", value: "1", matchRule: .regex)]
        #expect(try apply([step], url: "https://example.test/?key=old").url == "https://example.test/?key=old&%5B=1")
        step.queryParameterEntries = [QueryParameterEntry(operation: .modify, name: "*", value: "1", matchRule: .wildcard)]
        #expect(try apply([step], url: "https://example.test/?flag&&key=old&").url == "https://example.test/?flag=1&&key=1&")
    }

    @Test func queryMatchingDefaultsForExistingSavedEntries() throws {
        let entry = QueryParameterEntry(operation: .modify, name: "key", value: "1")
        var encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as! [String: Any]
        encoded.removeValue(forKey: "matchRule")
        let decoded = try JSONDecoder().decode(QueryParameterEntry.self, from: JSONSerialization.data(withJSONObject: encoded))
        #expect(decoded.matchRule == .equals && decoded == entry)
        #expect(WorkflowMatcher.matchesQueryParameterName("abc", rule: .wildcard, pattern: "a?c"))
        #expect(!WorkflowMatcher.matchesQueryParameterName("xabc", rule: .wildcard, pattern: "a?c"))
        #expect(WorkflowMatcher.matchesQueryParameterName("xabc", rule: .regex, pattern: "abc"))
    }

    @Test func replacementIsLiteralCaseSensitiveAndSupportsDeletion() throws {
        var step = ModificationStep(kind: .replaceURLString)
        step.name = "a.b"; step.value = "{{env.target}}"
        #expect(try apply([step], url: "https://example.test/a.b/aXb/A.B?q=a.b", environment: ["target": "next"]).url ==
            "https://example.test/next/aXb/A.B?q=next")
        step.name = "/next"; step.value = ""
        #expect(try apply([step], url: "https://example.test/next/path").url == "https://example.test/path")
        step.name = "absent"
        #expect(try apply([step], url: "https://example.test/").url == "https://example.test/")
    }

    @Test func replacementBlocksApplyInOrderAcrossTheWholeURLAndRoundTrip() throws {
        var step = ModificationStep(kind: .replaceURLString)
        step.value = "{{$env.unused}}"
        step.urlReplacementEntries = [
            URLReplacementEntry(search: "{{$env.search}}", replacement: "next"),
            URLReplacementEntry(search: "next", replacement: "final"),
            URLReplacementEntry(search: "/remove", replacement: "")
        ]
        let decoded = try JSONDecoder().decode(ModificationStep.self, from: JSONEncoder().encode(step))
        #expect(decoded == step)
        #expect(try apply([decoded], url: "https://old.test/old/old/remove?old=old&case=OLD", environment: ["search": "old"]).url ==
            "https://final.test/final/final?final=final&case=OLD")
        step.urlReplacementEntries = [URLReplacementEntry(search: "aa", replacement: "aaaa")]
        #expect(try apply([step], url: "https://example.test/aaaa").url == "https://example.test/aaaaaaaa")
    }

    @Test func replacementBlocksPreserveLegacyAndExplicitEmptyLists() throws {
        var step = ModificationStep(kind: .replaceURLString)
        step.name = "old"; step.value = "new"
        let legacy = try JSONDecoder().decode(ModificationStep.self, from: JSONEncoder().encode(step))
        #expect(legacy.urlReplacements == nil)
        #expect(legacy.urlReplacementEntries[0].id == legacy.id)
        step.urlReplacementEntries = legacy.urlReplacementEntries
        #expect(try apply([step], url: "https://old.test/old").url == "https://new.test/new")
        step.urlReplacementEntries = []
        step.value = "{{$env.missing}}"
        let decoded = try JSONDecoder().decode(ModificationStep.self, from: JSONEncoder().encode(step))
        #expect(decoded.urlReplacements == [])
        #expect(try apply([decoded], url: "https://old.test/old").url == "https://old.test/old")
    }

    @Test func replacementBlockFailuresLeaveTheWholeStepUnapplied() {
        for invalid in [URLReplacementEntry(search: "", replacement: "new"),
                        URLReplacementEntry(search: "next", replacement: "{{$env.missing}}"),
                        URLReplacementEntry(search: "next", replacement: "bad value"),
                        URLReplacementEntry(search: "{{$env.missing}}", replacement: "new")] {
            var step = ModificationStep(kind: .replaceURLString)
            step.urlReplacementEntries = [URLReplacementEntry(search: "old", replacement: "next"), invalid]
            var draft = HTTPMessageDraft(method: "GET", url: "https://example.test/old")
            var applied: [ModificationKind] = []
            #expect(throws: WorkflowError.self) {
                try WorkflowEngine.apply([step], response: false, to: &draft, environment: [:], id: UUID(), date: Date(), onApplied: { applied.append($0) })
            }
            #expect(draft.url == "https://example.test/old" && applied.isEmpty)
        }
    }

    @Test func stepsComposeInOrderAndRoundTrip() throws {
        var query = ModificationStep(kind: .setQueryParameter); query.name = "version"; query.value = "v1"
        var replace = ModificationStep(kind: .replaceURLString); replace.name = "v1"; replace.value = "v2"
        var workflow = RequestWorkflow(); workflow.requestSteps = [query, replace]
        var project = WorkflowProject(); project.workflows = [workflow]
        var document = WorkspaceDocument(); document.projects = [project]
        let decoded = try JSONDecoder().decode(WorkspaceDocument.self, from: JSONEncoder().encode(document))
        #expect(decoded == document)
        let steps = decoded.projects[0].workflows[0].requestSteps
        #expect(try apply(steps, url: "https://example.test/v1").url == "https://example.test/v2?version=v2")
        replace.enabled = false
        #expect(try apply([query, replace], url: "https://example.test/v1").url == "https://example.test/v1?version=v1")
    }

    @Test func invalidEditsFailWithoutMutatingURLOrReportingApplied() {
        for kind in [ModificationKind.setQueryParameter, .replaceURLString] {
            var step = ModificationStep(kind: kind); step.value = "new"
            #expect(throws: WorkflowError.self) { try apply([step], url: "https://example.test/") }
            step.name = "key"
            var response = HTTPMessageDraft(method: "GET", url: "https://example.test/")
            #expect(throws: WorkflowError.self) {
                try WorkflowEngine.apply([step], response: true, to: &response, environment: [:], id: UUID(), date: Date())
            }
        }
        for replacement in ["file:///tmp/x", "https://user:pass@example.test/", "https://example.test/#fragment", "https://example.test/\r\n", "https://example.test/a b", "https://"] {
            var step = ModificationStep(kind: .replaceURLString)
            step.name = "https://example.test/"; step.value = replacement
            var draft = HTTPMessageDraft(method: "GET", url: step.name)
            var applied: [ModificationKind] = []
            #expect(throws: WorkflowError.self) {
                try WorkflowEngine.apply([step], response: false, to: &draft, environment: [:], id: UUID(), date: Date(), onApplied: { applied.append($0) })
            }
            #expect(draft.url == step.name && applied.isEmpty)
        }
    }
}
