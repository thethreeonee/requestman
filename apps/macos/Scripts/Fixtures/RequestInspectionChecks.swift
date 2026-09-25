import Foundation
import RequestmanCore

@main
struct RequestInspectionChecks {
    static func main() throws {
        checkHeaders()
        try checkJSON()
        try checkJSONStringPreviews()
        try checkUnavailableAndLimits()
        try runBodyDecodingChecks()
        try runPayloadPresentationChecks()
        try runCURLChecks()
        print("Inspector checks passed: Header pairing, safe differences, JSON types/subtrees, filtering and bounds")
        print("No App built or launched; pasteboard and network unchanged")
    }

    private static func checkHeaders() {
        let before = [HTTPField("X-Test", "first"), HTTPField("x-test", "second"), HTTPField("Remove", "old")]
        let after = [HTTPField("x-test", "first"), HTTPField("X-TEST", "changed"), HTTPField("Added", "new")]
        let diff = RequestInspectionData.headers(
            original: before, final: after, originalInfo: .init(), finalInfo: .init(), version: .difference
        )
        precondition(diff.count == 4)
        precondition(Set(diff.map(\.id)).count == 4, "Repeated Header names need distinct identity")
        precondition(diff.map(\.change) == [.unchanged, .modified, .removed, .added])
        precondition(diff[1].originalValue == "second" && diff[1].copyValue == "changed")
        precondition(diff[2].copyValue == "old", "Removed Header copies its original value")
        let old = RequestInspectionData.headers(
            original: before, final: after, originalInfo: .init(), finalInfo: .init(), version: .original
        )
        precondition(old[1].value == "second" && old[1].change == .modified && old[1].originalValue == nil)
        let new = RequestInspectionData.headers(
            original: before, final: after, originalInfo: .init(), finalInfo: .init(), version: .final
        )
        precondition(new.count == 3 && new[1].id == old[1].id)
        precondition(new[2].change == .added && new[2].name == "Added")

        var limited = CaptureHeadersInfo()
        limited.isTruncated = true
        limited.truncatedNames = ["authorization", "x-long"]
        let uncertain = RequestInspectionData.headers(
            original: [HTTPField("Authorization", "hidden"), HTTPField("X-Long", "abc…"), HTTPField("Missing", "1")],
            final: [HTTPField("authorization", "other"), HTTPField("x-long", "ab…"), HTTPField("New", "2")],
            originalInfo: limited, finalInfo: limited, version: .difference
        )
        precondition(uncertain.allSatisfy { $0.change == .unchanged }, "Unavailable Header values cannot establish differences")

        var credentials = CaptureRecord(method: "GET", url: "https://example.test/")
        credentials.requestHeaders = [HTTPField("Authorization", "Bearer original"), HTTPField("X-API-Key", "old-key")]
        credentials.sentHeaders = [HTTPField("Authorization", "Bearer modified"), HTTPField("X-API-Key", "new-key")]
        credentials = credentials.bounded()
        let credentialDiff = RequestInspectionData.headers(original: credentials.requestHeaders, final: credentials.sentHeaders,
            originalInfo: credentials.requestHeadersInfo, finalInfo: credentials.sentHeadersInfo, version: .difference)
        precondition(credentialDiff.allSatisfy { $0.change == .modified })
        precondition(credentialDiff[0].originalValue == "Bearer original" && credentialDiff[0].copyValue == "Bearer modified")

        let cookie = "session=" + String(repeating: "a", count: 8_192)
        var record = CaptureRecord(method: "GET", url: "https://example.test/")
        record.requestHeaders = [HTTPField("Cookie", cookie + "-old")]
        record.sentHeaders = [HTTPField("Cookie", cookie + "-new")]
        record.receivedHeaders = [HTTPField("Set-Cookie", cookie + "-server; HttpOnly")]
        record.responseHeaders = [HTTPField("Set-Cookie", cookie + "-client; HttpOnly")]
        record = record.bounded().bounded()
        let snapshots = [
            (record.requestHeaders, record.sentHeaders, record.requestHeadersInfo, record.sentHeadersInfo),
            (record.receivedHeaders, record.responseHeaders, record.receivedHeadersInfo, record.responseHeadersInfo)
        ]
        for (original, final, originalInfo, finalInfo) in snapshots {
            precondition(!originalInfo.isTruncated && !finalInfo.isTruncated)
            let nodes = RequestInspectionData.headers(original: original, final: final,
                originalInfo: originalInfo, finalInfo: finalInfo, version: .difference)
            precondition(nodes.count == 1 && nodes[0].change == .modified)
            precondition(nodes[0].originalValue == original[0].value && nodes[0].copyValue == final[0].value,
                         "Long Cookie and Set-Cookie values must retain their differing suffixes for comparison and copying")
        }
    }

    private static func checkJSON() throws {
        let before = data(#"{"object":{"name":"old","enabled":true},"list":[1,2],"removed":"value","empty":null}"#)
        let after = data(#"{"object":{"name":"new","enabled":1},"list":[1,2,3],"added":{"deep":"copy me"},"empty":null}"#)
        let roots = try RequestInspectionData.json(original: before, final: after, version: .difference)
        precondition(roots.count == 1 && roots[0].id == "$" && roots[0].change == .modified)
        precondition(!roots[0].highlightsChange, "Descendant edits cannot tint every ancestor row")
        let nodes = flattened(roots)
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        precondition(byID[#"$["object"]["name"]"#]?.originalValue == #""old""#)
        precondition(byID[#"$["object"]["name"]"#]?.copyValue == #""new""#)
        let number = byID[#"$["object"]["enabled"]"#]!
        precondition(number.change == .modified && number.valueKind == .number && number.originalValue == "true")
        precondition(number.highlightsChange && byID[#"$["object"]"#]?.highlightsChange == false)
        precondition(byID[#"$["list"]"#]?.highlightsChange == true, "Container count changes remain visible")
        precondition(byID[#"$["removed"]"#]?.change == .removed)
        precondition(byID[#"$["removed"]"#]?.copyValue == #""value""#)
        precondition(byID[#"$["list"][2]"#]?.change == .added)
        let added = byID[#"$["added"]"#]!
        precondition(added.change == .added && added.children[0].change == .added)
        let subtree = try JSONSerialization.jsonObject(with: data(added.copyValue)) as? [String: String]
        precondition(subtree == ["deep": "copy me"], "Copy payload must contain the full subtree")
        let copiedRoot = try JSONSerialization.jsonObject(with: data(roots[0].copyValue)) as! NSDictionary
        let finalRoot = try JSONSerialization.jsonObject(with: after) as! NSDictionary
        precondition(copiedRoot == finalRoot, "Difference root copies the final body, without removed fields")

        let old = flattened(try RequestInspectionData.json(original: before, final: after, version: .original))
        let boolean = old.first { $0.id == number.id }!
        precondition(boolean.valueKind == .boolean && boolean.copyValue == "true" && boolean.change == .modified)
        let equal = try RequestInspectionData.json(original: after, final: after, version: .difference)
        precondition(flattened(equal).allSatisfy { $0.change == .unchanged })

        let filtered = RequestInspectionData.filtering(roots, query: "copy me", onlyChanges: false)
        precondition(filtered[0].children.count == 1 && filtered[0].children[0].name == "added")
        precondition(filtered[0].copyValue == roots[0].copyValue, "Filtering cannot change the copied subtree")
        precondition(!filtered[0].highlightsChange, "Filtering must preserve ancestor background semantics")
        let object = RequestInspectionData.filtering(roots, query: "object", onlyChanges: false)
        precondition(object[0].children[0].children.count == 2, "Matching a container includes its children")
        let changed = flattened(RequestInspectionData.filtering(roots, query: "", onlyChanges: true))
        precondition(!changed.contains { $0.name == "empty" || $0.id == #"$["list"][0]"# })
        precondition(RequestInspectionData.filtering(roots, query: "absent-match", onlyChanges: true).isEmpty)

        let awkward = data(#"{"a.b[0]\"x":{"雪":[false,null,"a\nb"]}}"#)
        let escaped = try RequestInspectionData.json(original: awkward, final: awkward, version: .final)
        let escapedIDs = flattened(escaped).map(\.id)
        precondition(Set(escapedIDs).count == escapedIDs.count)
        precondition(escapedIDs.contains(#"$["a.b[0]\"x"]["雪"][1]"#))
        let scalar = try RequestInspectionData.json(original: data("false"), final: data("1"), version: .difference)
        precondition(scalar[0].valueKind == .number && scalar[0].originalValue == "false")
        let typeChange = try RequestInspectionData.json(original: data("[1,2]"), final: data(#"{"x":true}"#), version: .difference)
        precondition(typeChange[0].change == .modified && typeChange[0].children[0].change == .unchanged)
        precondition(typeChange[0].highlightsChange && !typeChange[0].children[0].highlightsChange)
        let arrayChange = try RequestInspectionData.json(original: data(#"{"0":"old"}"#), final: data("[false]"), version: .difference)
        precondition(arrayChange[0].change == .modified && arrayChange[0].children[0].change == .unchanged)
        precondition(arrayChange[0].children[0].id == "$[0]", "Object keys and array indices cannot be paired across a type change")
        let scalarChange = try RequestInspectionData.json(original: data(#"{"x":true}"#), final: data("false"), version: .difference)
        precondition(scalarChange[0].change == .modified && scalarChange[0].children.isEmpty)
        precondition(scalarChange[0].copyValue == "false")
    }

    private static func checkJSONStringPreviews() throws {
        let embedded = #"{"items":[true,2,null],"nested":"{\"answer\":42}"}"#
        let outer = try JSONSerialization.data(withJSONObject: ["encoded": embedded, "plain": "hello"])
        let roots = try RequestInspectionData.json(original: nil, final: outer, version: .final)
        let encoded = roots[0].children.first { $0.name == "encoded" }!
        precondition(encoded.valueKind == .string && encoded.children.isEmpty)
        precondition(encoded.jsonStringValue == embedded)
        let copied = try JSONSerialization.jsonObject(with: data(encoded.copyValue), options: [.fragmentsAllowed]) as? String
        precondition(copied == embedded, "Preview cannot replace the original field's string copy payload")
        let preview = RequestInspectionData.stringJSONPreview(encoded.jsonStringValue!)!
        precondition(preview[0].typeName == "Object" && preview[0].children.count == 2)
        precondition(flattened(preview).allSatisfy { $0.change == .unchanged })
        let nested = preview[0].children.first { $0.name == "nested" }!
        let secondPreview = RequestInspectionData.stringJSONPreview(nested.jsonStringValue!)!
        precondition(secondPreview[0].children[0].copyValue == "42", "Nested JSON strings remain inspectable")
        precondition(RequestInspectionData.filtering(roots, query: "encoded", onlyChanges: false)[0].children[0].jsonStringValue == embedded)
        precondition(roots[0].jsonStringValue == nil && secondPreview[0].children[0].jsonStringValue == nil)

        for valid in ["[]", "{}", " true ", "42", "null", #""a string""#] {
            precondition(RequestInspectionData.stringJSONPreview(valid)?.count == 1, "JSON fragments are valid previews")
        }
        for invalid in ["", "hello", "{broken}", "{} trailing", "[1,] trailing"] {
            precondition(RequestInspectionData.stringJSONPreview(invalid) == nil)
        }
        precondition(RequestInspectionData.stringJSONPreview(String(repeating: " ", count: 1_048_576) + "{}") != nil)
        precondition(RequestInspectionData.stringJSONPreview(String(repeating: "[", count: 65) + "0" + String(repeating: "]", count: 65)) != nil)
        precondition(RequestInspectionData.stringJSONPreview("[" + Array(repeating: "0", count: 5_000).joined(separator: ",") + "]") != nil)

        let before = try JSONSerialization.data(withJSONObject: ["value": "[1]"])
        let after = try JSONSerialization.data(withJSONObject: ["value": "[2]"])
        let original = try RequestInspectionData.json(original: before, final: after, version: .original)
        let difference = try RequestInspectionData.json(original: before, final: after, version: .difference)
        precondition(original[0].children[0].jsonStringValue == "[1]")
        precondition(difference[0].children[0].jsonStringValue == "[2]", "Preview follows the displayed version")

        var headerInfo = CaptureHeadersInfo()
        headerInfo.truncatedNames = ["x-partial"]
        let headers = RequestInspectionData.headers(original: [],
            final: [HTTPField("X-JSON", embedded), HTTPField("X-Private", "{}"), HTTPField("X-Partial", "[]")],
            originalInfo: .init(), finalInfo: headerInfo, version: .final)
        precondition(headers[0].jsonStringValue == embedded)
        precondition(headers[1].jsonStringValue == "{}" && headers[2].jsonStringValue == nil,
                     "Incomplete headers cannot masquerade as complete JSON")
        var truncatedInfo = CaptureHeadersInfo()
        truncatedInfo.truncatedNames = ["x-json"]
        let fields = [HTTPField("X-JSON", "{}")]
        let finalComplete = RequestInspectionData.headers(original: fields, final: fields,
            originalInfo: truncatedInfo, finalInfo: .init(), version: .final)
        let originalComplete = RequestInspectionData.headers(original: fields, final: fields,
            originalInfo: .init(), finalInfo: truncatedInfo, version: .original)
        let finalDifference = RequestInspectionData.headers(original: fields, final: fields,
            originalInfo: truncatedInfo, finalInfo: .init(), version: .difference)
        precondition([finalComplete, originalComplete, finalDifference].allSatisfy { $0[0].jsonStringValue == "{}" },
                     "An unavailable counterpart cannot suppress a complete displayed value's preview")
        let removed = RequestInspectionData.headers(original: fields, final: [],
            originalInfo: truncatedInfo, finalInfo: .init(), version: .difference)
        precondition(removed[0].jsonStringValue == nil, "Removed fields follow the original capture completeness")
    }

    private static func checkUnavailableAndLimits() throws {
        let body = data(#"{"answer":42}"#)
        let missingOriginal = try RequestInspectionData.json(original: nil, final: body, version: .original)
        precondition(missingOriginal.isEmpty)
        let onlyFinal = try RequestInspectionData.json(original: nil, final: body, version: .difference)
        precondition(flattened(onlyFinal).allSatisfy { $0.change == .unchanged })
        let onlyOriginal = try RequestInspectionData.json(original: body, final: nil, version: .difference)
        precondition(flattened(onlyOriginal).allSatisfy { $0.change == .unchanged })
        let textFinal = try RequestInspectionData.json(original: body, final: data("not JSON"), version: .original)
        precondition(textFinal[0].children[0].value == "42")
        let null = try RequestInspectionData.json(original: nil, final: data("null"), version: .final)
        precondition(null[0].valueKind == .null && null[0].copyValue == "null")

        assertThrows { _ = try RequestInspectionData.json(original: nil, final: data("{"), version: .final) }
        let nested = String(repeating: "[", count: 128) + "0" + String(repeating: "]", count: 128)
        let deep = try RequestInspectionData.json(original: nil, final: data(nested), version: .final)
        precondition(flattened(deep).count == 129)
        let many = "[" + Array(repeating: "0", count: 5_000).joined(separator: ",") + "]"
        let wide = try RequestInspectionData.json(original: nil, final: data(many), version: .final)
        precondition(wide[0].children.count == 5_000)
        let large = data("\"" + String(repeating: "x", count: 1_048_576) + "\"")
        let largeString = try RequestInspectionData.json(original: nil, final: large, version: .final)
        precondition(largeString[0].copyValue.utf8.count == large.count)
        let bracesInString = data("\"" + String(repeating: "[", count: 128) + "\"")
        let string = try RequestInspectionData.json(original: nil, final: bracesInString, version: .final)
        precondition(string[0].valueKind == .string, "Brackets inside strings do not increase nesting")
    }

    private static func data(_ string: String) -> Data { Data(string.utf8) }
    private static func flattened(_ nodes: [RequestDataNode]) -> [RequestDataNode] {
        nodes.flatMap { [$0] + flattened($0.children) }
    }
    private static func assertThrows(_ action: () throws -> Void) {
        do { try action(); preconditionFailure("Expected invalid JSON to be rejected") }
        catch {}
    }
}
