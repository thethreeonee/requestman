import Foundation
import Testing
@testable import RequestmanCore

struct WorkflowDelayTests {
    @Test func configurationAndValidation() throws {
        var step = ModificationStep(kind: .delay)
        #expect(step.value == "1000")
        #expect(step.kind.supports(response: true) && !step.kind.supports(response: false))
        step.value = "250"
        #expect(try JSONDecoder().decode(ModificationStep.self, from: JSONEncoder().encode(step)) == step)
        for value in ["", "-1", "1.5", "1e3", "abc", " 10", "999999999999999999999999"] {
            #expect(throws: WorkflowError.self) { try WorkflowEngine.delayMilliseconds(value) }
        }
        #expect(try WorkflowEngine.delayMilliseconds("0") == 0)
        #expect(try WorkflowEngine.delayMilliseconds(String(Int.max)) == Int.max)
    }

    @Test func waitsBeforeFollowingStepAndPreservesPhaseSnapshot() async throws {
        var delay = ModificationStep(kind: .delay); delay.value = "80"
        var status = ModificationStep(kind: .setStatus); status.status = 201
        var header = ModificationStep(kind: .setHeader); header.name = "X-Original-Status"; header.value = "{{$response.status}}"
        var draft = HTTPMessageDraft(method: "GET", url: "http://localhost/", status: 200)
        let start = ContinuousClock.now
        var applied: [ModificationKind] = []
        let trace = try await WorkflowEngine.applyAsync([status, delay, header, delay], response: true, to: &draft,
            environment: [:], id: UUID(), date: Date()) { kind in
                if kind == .setHeader { #expect(start.duration(to: .now) >= .milliseconds(80)) }
                applied.append(kind)
            }
        #expect(start.duration(to: .now) >= .milliseconds(160))
        #expect(applied == [.setStatus, .delay, .setHeader, .delay])
        #expect(trace == applied.map(\.title))
        #expect(draft.status == 201 && draft.headers == [HTTPField("X-Original-Status", "200")])
    }

    @Test func zeroAndDisabledStepsContinueImmediately() async throws {
        var disabled = ModificationStep(kind: .delay); disabled.enabled = false; disabled.value = "invalid"
        var zero = ModificationStep(kind: .delay); zero.value = "0"
        var status = ModificationStep(kind: .setStatus); status.status = 202
        var draft = HTTPMessageDraft(method: "GET", url: "http://localhost/")
        let trace = try await WorkflowEngine.applyAsync([disabled, zero, status], response: true, to: &draft,
            environment: [:], id: UUID(), date: Date())
        #expect(trace == [ModificationKind.delay.title, ModificationKind.setStatus.title])
        #expect(draft.status == 202)
    }

    @Test func invalidDelayAndWrongPhaseDoNotAdvance() async {
        for response in [false, true] {
            var step = ModificationStep(kind: .delay); step.value = response ? "-1" : "0"
            var body = ModificationStep(kind: .replaceBody); body.value = "should not run"
            var draft = HTTPMessageDraft(method: "GET", url: "http://localhost/")
            do {
                _ = try await WorkflowEngine.applyAsync([step, body], response: response, to: &draft,
                    environment: [:], id: UUID(), date: Date())
                Issue.record("Invalid delay or phase must fail")
            } catch { #expect(error is WorkflowError) }
            #expect(draft.replacementBody == nil)
        }
    }

    @Test func cancellationStopsBeforeNextStep() async throws {
        let control = ScriptExecutionControl()
        let canceller = Task {
            try await Task.sleep(for: .milliseconds(50)); control.cancel()
        }
        var delay = ModificationStep(kind: .delay); delay.value = String(Int.max)
        var status = ModificationStep(kind: .setStatus); status.status = 201
        var draft = HTTPMessageDraft(method: "GET", url: "http://localhost/")
        let start = ContinuousClock.now
        var applied: [ModificationKind] = []
        do {
            _ = try await WorkflowEngine.applyAsync([delay, status], response: true, to: &draft,
                environment: [:], id: UUID(), date: Date(), control: control, onApplied: { applied.append($0) })
            Issue.record("Cancelled delay must fail")
        } catch { #expect(error is WorkflowError) }
        #expect(applied.isEmpty && draft.status == 200)
        #expect(start.duration(to: .now) < .seconds(2))
        try await canceller.value
    }
}
