import Foundation
import NIOCore
import RequestmanCore

extension ProxyConnection {
    func applyRecordedSteps(response: Bool, to draft: inout HTTPMessageDraft) throws {
        guard let transaction else { return }
        let result = try transaction.execute(&draft, phase: response ? .response : .request, request: request) { trace in
            self.traceRecorder?.append(trace)
            self.recordStep(trace)
        }
        if !response { requestDisposition = result.disposition }
    }

    func recordStep(_ trace: StepExecutionTrace) {
        guard let match else { return }
        record?.executionTrace.append(trace)
        guard trace.status == .applied else { return }
        record?.steps.append(trace.kind.title)
        record?.matchedRules.append(CaptureMatchedRule(kind: trace.kind, name: match.workflow.name,
            response: trace.phase == .response))
    }

    func reserveScriptFlow() -> Bool {
        if scriptLease != nil { return true }
        scriptLease = ScriptFlowLease.acquire()
        if scriptLease == nil { fail("脚本流程执行已满", status: 503); return false }
        return true
    }

    /// Bridge one planned operation to the background executor; packet forwarding stays on NIO.
    func executeScriptFlow(response isResponse: Bool, draft: HTTPMessageDraft,
                           completion: @escaping @Sendable (HTTPMessageDraft) -> Void) {
        guard let client, let transaction, let snapshot = record else { return }
        let phase: FlowPhase = isResponse ? .response : .request
        let hasScript = transaction.requirements(for: phase).hasScripts
        if hasScript { guard reserveScriptFlow() else { return } }
        let lease = scriptLease
        let control = transaction.context.control
        suspendedFlowControl = control
        var requestSnapshot = request
        if isResponse, requestSnapshot?.bodyText == nil, let requestBodyCollector, requestEnded {
            let body = requestBodyCollector.snapshot(isComplete: true)
            requestSnapshot?.bodyData = body.data
        }
        if snapshot.hasSentRequestHeaders { requestSnapshot?.headers = snapshot.sentHeaders }
        let recorder = traceRecorder
        let inputRequest = requestSnapshot
        Task.detached(priority: .userInitiated) { [self, lease] in
            // Keep admission until the worker exits, including across suspended delays.
            defer { withExtendedLifetime(lease) {} }
            var output = draft
            var trace: [StepExecutionTrace] = []
            let result: Result<ModificationExecutionResult, Error>
            do {
                try control.check()
                if transaction.requirements(for: phase).needsCompleteBody, !output.hasReplacementBody, let data = output.bodyData {
                    output.bodyText = try ScriptBodyText.decode(data, headers: output.headers, control: control)
                }
                var preparedRequest = inputRequest
                if hasScript, let data = preparedRequest?.bodyData, preparedRequest?.hasReplacementBody != true {
                    let headers = preparedRequest?.headers ?? []
                    preparedRequest?.bodyText = try ScriptBodyText.decode(data, headers: headers, control: control)
                }
                result = .success(try await transaction.executeAsync(&output, phase: phase, request: preparedRequest,
                    onTrace: { recorder?.append($0); trace.append($0) }))
            } catch { result = .failure(error) }
            let appliedTrace = trace, finalOutput = output
            // Cancellation has already finalized transport; the independent recorder keeps late traces.
            guard !control.isCancelled else { return }
            client.eventLoop.execute { [self] in
                guard isProcessing, record?.id == snapshot.id else { return }
                suspendedFlowControl = nil
                for step in appliedTrace { recordStep(step) }
                switch result {
                case .success(let execution):
                    if !isResponse { requestDisposition = execution.disposition }
                    completion(finalOutput)
                case .failure(let error): fail(error.localizedDescription, status: isResponse ? 502 : 400)
                }
            }
        }
    }
}
