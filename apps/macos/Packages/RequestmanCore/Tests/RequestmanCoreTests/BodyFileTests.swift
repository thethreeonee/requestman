import Foundation
import Testing
@testable import RequestmanCore

struct BodyFileTests {
    @Test func readsCurrentBytesForBothDirectionsAndMock() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("requestman-body-\(UUID()).bin")
        defer { _ = try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        for (kind, response) in [(ModificationKind.replaceBody, false), (.replaceBody, true), (.mock, false)] {
            var step = ModificationStep(kind: kind)
            step.bodySource = .file; step.bodyFilePath = url.path
            step.value = "{{$env.missing}}" // Inactive text and templates must not be evaluated.
            step.bodyEncoding = .base64
            for bytes in [Data([0, 255, 128, 13, 10]), Data("{{literal}}\r\n更新".utf8), Data()] {
                try bytes.write(to: url, options: .atomic)
                var draft = HTTPMessageDraft(method: "POST", url: "http://example.test/", headers: [HTTPField("Content-Encoding", "gzip"), HTTPField("ETag", "old")])
                _ = try WorkflowEngine.apply([step], response: response, to: &draft, environment: [:], id: UUID(), date: Date())
                #expect(draft.replacementBytes == bytes)
                #expect(draft.replacementBody == nil)
                #expect(draft.isMock == (kind == .mock))
                #expect(!draft.headers.contains { ["Content-Encoding", "ETag"].contains($0.name) })
            }
        }
    }

    @Test func missingOrInvalidFileFailsWithoutChangingDraft() throws {
        for path in [nil, "", "/tmp/requestman-missing-\(UUID())", FileManager.default.temporaryDirectory.path] as [String?] {
            var step = ModificationStep(kind: .replaceBody); step.bodySource = .file; step.bodyFilePath = path
            var draft = HTTPMessageDraft(method: "GET", url: "http://example.test/")
            draft.replacementBody = "original"
            #expect(throws: WorkflowError.self) {
                try WorkflowEngine.apply([step], response: false, to: &draft, environment: [:], id: UUID(), date: Date())
            }
            #expect(draft.replacementBody == "original")
        }
    }

    @Test func roundTripAndOldWorkspaceDefaultToText() throws {
        var step = ModificationStep(kind: .mock); step.value = "manual text"
        let legacy = try JSONDecoder().decode(ModificationStep.self, from: JSONEncoder().encode(step))
        #expect(legacy.bodySource == nil && !legacy.usesBodyFile)
        step.bodySource = .file; step.bodyFilePath = "/tmp/body.json"
        #expect(try JSONDecoder().decode(ModificationStep.self, from: JSONEncoder().encode(step)) == step)
        step.bodySource = .text
        var draft = HTTPMessageDraft(method: "GET", url: "http://example.test/")
        _ = try WorkflowEngine.apply([step], response: false, to: &draft, environment: [:], id: UUID(), date: Date())
        #expect(draft.replacementBody == "manual text")
    }
}
