import Foundation
import os
import Testing
@testable import RequestmanCore

@Suite(.serialized)
struct ScriptAsyncTests {
    private func run(_ source: String, client: (any ScriptHTTPClient)? = nil, timeout: Int = 3000,
                     control: ScriptExecutionControl = .init(), parent: UUID? = nil, step: UUID? = nil) async throws -> HTTPMessageDraft {
        try await WorkflowScript.runAsync(source: source, draft: .init(method: "GET", url: "https://main.test/"),
            response: false, request: nil, environment: [:], timeoutMilliseconds: timeout,
            control: control, httpClient: client, parentTransactionID: parent, stepID: step)
    }

    @Test func purePromisesAwaitAndRejectedResults() async throws {
        let output = try await run("request.method = await Promise.resolve('PATCH'); return Promise.resolve(request);")
        #expect(output.method == "PATCH")
        await #expect(throws: WorkflowError.self) { try await run("await Promise.reject(new Error('rejected')); return request;") }
        await #expect(throws: WorkflowError.self) { try await run("return Promise.resolve(4);") }
    }

    @Test func headersResolveWithoutReadingBodyAndUnreadResponseIsCancelled() async throws {
        let client = ScriptTestHTTPClient(), parent = UUID(), step = UUID()
        let output = try await run("const r = await fetch('https://aux.test/headers'); request.method = r.status === 401 && !r.ok ? 'PATCH' : 'POST'; return request;",
            client: client, parent: parent, step: step)
        #expect(output.method == "PATCH")
        let state = await client.snapshot()
        #expect(state.reads == 0 && state.cancellations == 1)
        #expect(state.contexts.first?.parentTransactionID == parent && state.contexts.first?.stepID == step)
    }

    @Test func bodyReadWaitsForItsHeaderWriteAndOtherCallsStillProgress() async throws {
        let client = ScriptTestHTTPClient(), gate = ScriptHeaderWriteGate(), id = UUID(), otherID = UUID()
        let broker = ScriptHTTPBroker(client: client, parentID: nil, stepID: nil,
            send: { message in await gate.send(message) })
        let request = try JSONEncoder().encode(ScriptHTTPRequest(url: "https://aux.test/json"))
        await broker.receive(.init(kind: "fetch", id: id, data: request))
        await gate.waitForFirstHeaders()
        await broker.receive(.init(kind: "body", id: id))
        await broker.receive(.init(kind: "fetch", id: otherID, data: request))
        await gate.waitForOtherHeaders()
        // The second call's header delivery proves admission continues while the first write is held.
        // Give an incorrectly admitted body task a chance to reach the transport before releasing it.
        try await Task.sleep(for: .milliseconds(40))
        #expect(await client.snapshot().reads == 0)
        await gate.releaseFirstHeaders()
        await gate.waitForBodyEnd()
        #expect(await client.snapshot().reads == 1)
        await broker.shutdown()
    }

    @Test func bodyConsumptionJSONHeadersAndBinaryRequest() async throws {
        let client = ScriptTestHTTPClient()
        let output = try await run("""
        const headers = new Headers([['X-Value','first'],['X-Value','second']]);
        headers.set('X-Set','yes'); headers.append('X-Set','again');
        if (headers.get('x-value') !== 'first, second' || [...headers].length !== 2) throw new Error('headers');
        const r = await fetch('https://aux.test/json', {method:'POST',headers,body:new Uint8Array([0,255,1])});
        if (r.bodyUsed || r.headers.getSetCookie().length !== 2) throw new Error('response headers');
        const value = await r.json();
        if (!r.bodyUsed) throw new Error('bodyUsed');
        try { await r.text(); throw new Error('read twice'); } catch (e) { if (e.message === 'read twice') throw e; }
        request.body = value.token; return request;
        """, client: client)
        #expect(output.replacementBody == "令牌")
        let state = await client.snapshot()
        #expect(state.reads == 1)
        #expect(state.requests.first?.body == Data([0,255,1]))
        #expect(state.requests.first?.headers.filter { $0.name == "x-value" }.count == 2)
    }

    @Test func largeChunkedResponseAndArrayBuffer() async throws {
        let client = ScriptTestHTTPClient()
        let output = try await run("""
        const [text, bytes] = await Promise.all([
          fetch('https://aux.test/large').then(r => r.text()),
          fetch('https://aux.test/binary').then(r => r.arrayBuffer())
        ]);
        const data = new Uint8Array(bytes);
        request.body = text + ':' + [...data].join(','); return request;
        """, client: client, timeout: 10000)
        #expect(output.replacementBody == String(repeating: "字😀", count: 100_000) + ":0,255,1")
    }

    @Test func promiseAllUsesBoundedAdmission() async throws {
        let client = ScriptTestHTTPClient()
        let output = try await run("""
        const values = await Promise.all(Array.from({length:12}, (_,i) =>
          fetch('https://aux.test/json?i='+i).then(r => r.json())));
        request.body = String(values.length); return request;
        """, client: client, timeout: 10000)
        #expect(output.replacementBody == "12")
        let state = await client.snapshot()
        #expect(state.maximumActive <= 4 && state.requests.count == 12 && state.reads == 12)
    }

    @Test func fetchAbortStormIsBoundedBeforeNativeIPCSubmission() async throws {
        let client = ScriptTestHTTPClient()
        let output = try await run("""
        const tasks = [];
        for (let i = 0; i < 1000; i++) {
          const c = new AbortController();
          const p = fetch('https://aux.test/slow', {signal:c.signal});
          tasks.push(p); c.abort();
        }
        const results = await Promise.allSettled(tasks);
        request.body = String(results.length); return request;
        """, client: client, timeout: 10000)
        #expect(output.replacementBody == "1000")
        let state = await client.snapshot()
        #expect(state.requests.count <= 36 && state.maximumActive <= 4)
    }

    @Test func returningWithUnawaitedFetchCancelsItWithoutOverridingScriptResult() async throws {
        let client = ScriptTestHTTPClient()
        #expect(try await run("fetch('https://aux.test/slow').catch(()=>{}); return request;", client: client).method == "GET")
    }

    @Test func abortAfterHeadersRejectsBodyAndCancelsTransport() async throws {
        let client = ScriptTestHTTPClient()
        let output = try await run("""
        const c = new AbortController();
        const r = await fetch('https://aux.test/json', {signal:c.signal});
        c.abort();
        try { await r.text(); throw new Error('not aborted'); }
        catch(e) { request.body = e.name; }
        return request;
        """, client: client)
        #expect(output.replacementBody == "AbortError")
        #expect(await client.snapshot().cancellations >= 1)
    }

    @Test func timeoutAndCancellationKillWorkerAndNetwork() async throws {
        let client = ScriptTestHTTPClient()
        await #expect(throws: WorkflowError.self) {
            try await run("await fetch('https://aux.test/slow'); return request;", client: client, timeout: 200)
        }
        let control = ScriptExecutionControl()
        let task = Task { try await run("await fetch('https://aux.test/slow'); return request;", client: client, timeout: 10000, control: control) }
        try await Task.sleep(for: .milliseconds(100)); control.cancel()
        await #expect(throws: WorkflowError.self) { try await task.value }
        #expect(try await run("return request;").method == "GET")
        #expect(await client.snapshot().maximumActive <= 4)
    }

    @Test func bodyFailuresRejectAndBodyWaitIsIncludedInDeadline() async throws {
        let client = ScriptTestHTTPClient()
        await #expect(throws: WorkflowError.self) {
            try await run("const r = await fetch('https://aux.test/brokenBody'); await r.text(); return request;", client: client)
        }
        await #expect(throws: WorkflowError.self) {
            try await run("const r = await fetch('https://aux.test/bodyWait'); await r.arrayBuffer(); return request;", client: client, timeout: 200)
        }
        #expect(await client.snapshot().cancellations >= 2)
    }

    @Test func unsupportedOptionsOfflineFetchAndNeverSettlingPromiseFailClearly() async throws {
        for source in ["await fetch('https://aux.test/'); return request;",
                       "await fetch('https://aux.test/', {credentials:'include'}); return request;",
                       "setTimeout(()=>{},1); return request;",
                       "await fetch('https://aux.test/', {method:'GET',body:'bad'}); return request;"] {
            await #expect(throws: WorkflowError.self) { try await run(source) }
        }
        await #expect(throws: WorkflowError.self) { try await run("return new Promise(()=>{});", timeout: 150) }
    }

    @Test func failedAsyncScriptDoesNotCommitItsDraftOrExecuteLaterSteps() async throws {
        var first = ModificationStep(kind: .setHeader); first.name = "X-First"; first.value = "kept"
        var script = ModificationStep(kind: .script)
        script.value = "request.headers.push({name:'X-Leaked',value:'bad'}); await Promise.reject(new Error('failed')); return request;"
        var later = ModificationStep(kind: .setMethod); later.value = "PATCH"
        var draft = HTTPMessageDraft(method: "GET", url: "https://main.test/")
        let context = ModificationExecutionContext(phase: .request, environment: [:], templateContext: .init(id: UUID(), date: Date()))
        await #expect(throws: WorkflowError.self) {
            try await ModificationExecutionEngine.executeAsync([first, script, later], to: &draft, context: context)
        }
        #expect(draft.method == "GET" && draft.headers == [HTTPField("X-First", "kept")])
    }

    @Test func cancellationCallbacksAreOnceReentrantAndLateHandlersRunImmediately() {
        let control = ScriptExecutionControl(), count = OSAllocatedUnfairLock(initialState: 0)
        let removed = control.addCancellationHandler { count.withLock { $0 += 100 } }
        control.removeCancellationHandler(removed)
        control.addCancellationHandler { count.withLock { $0 += 1 }; control.cancel() }
        control.cancel(); control.cancel()
        control.addCancellationHandler { count.withLock { $0 += 1 } }
        #expect(count.withLock { $0 } == 2)
    }

    @Test func oldMissingOptionsKeepTheirTimeoutAndNewScriptsUseTenSeconds() throws {
        let step = ModificationStep(kind: .script)
        #expect(step.effectiveScriptOptions.timeoutMilliseconds == 10000)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(step)) as? [String: Any])
        object.removeValue(forKey: "scriptOptions")
        let old = try JSONDecoder().decode(ModificationStep.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.effectiveScriptOptions.timeoutMilliseconds == 1000)
        var edited = old; edited.scriptOptions = ScriptOptions(); edited.scriptOptions?.timeoutMilliseconds = 500
        let restored = try JSONDecoder().decode(ModificationStep.self, from: JSONEncoder().encode(edited))
        #expect(restored.effectiveScriptOptions.timeoutMilliseconds == 500)
    }
}

/// Holds actual header delivery, independently of broker task bookkeeping.
private actor ScriptHeaderWriteGate {
    private var firstHeader: CheckedContinuation<Void, Never>?
    private var headerCount = 0
    private var firstHeaderWaiter: CheckedContinuation<Void, Never>?
    private var otherHeaderWaiter: CheckedContinuation<Void, Never>?
    private var bodyEnded = false
    private var bodyWaiter: CheckedContinuation<Void, Never>?
    func send(_ message: ScriptIPCMessage) async {
        if message.kind == "headers" {
            headerCount += 1
            if headerCount == 1 {
                firstHeaderWaiter?.resume(); firstHeaderWaiter = nil
                await withCheckedContinuation { firstHeader = $0 }
            } else { otherHeaderWaiter?.resume(); otherHeaderWaiter = nil }
        } else if message.kind == "bodyEnd" {
            bodyEnded = true; bodyWaiter?.resume(); bodyWaiter = nil
        }
    }
    func waitForFirstHeaders() async {
        if headerCount == 0 { await withCheckedContinuation { firstHeaderWaiter = $0 } }
    }
    func waitForOtherHeaders() async {
        if headerCount < 2 { await withCheckedContinuation { otherHeaderWaiter = $0 } }
    }
    func releaseFirstHeaders() { firstHeader?.resume(); firstHeader = nil }
    func waitForBodyEnd() async {
        if !bodyEnded { await withCheckedContinuation { bodyWaiter = $0 } }
    }
}

private actor ScriptTestHTTPClient: ScriptHTTPClient {
    struct Snapshot: Sendable {
        var reads = 0, cancellations = 0, active = 0, maximumActive = 0
        var contexts: [ScriptHTTPContext] = [], requests: [ScriptHTTPRequest] = []
    }
    private var state = Snapshot()
    private let cancellationCount = OSAllocatedUnfairLock(initialState: 0)
    func snapshot() -> Snapshot {
        var result = state; result.cancellations = cancellationCount.withLock { $0 }; return result
    }
    func send(_ request: ScriptHTTPRequest, context: ScriptHTTPContext,
              control: ScriptExecutionControl) async throws -> ScriptHTTPResponse {
        state.requests.append(request); state.contexts.append(context)
        state.active += 1; state.maximumActive = max(state.maximumActive, state.active)
        defer { state.active -= 1 }
        if request.url.contains("slow") {
            while !control.isCancelled { try await Task.sleep(for: .milliseconds(20)) }
            try control.check()
        }
        try await Task.sleep(for: .milliseconds(10))
        try control.check()
        let cancelCount = cancellationCount
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return ScriptHTTPResponse(status: request.url.contains("headers") ? 401 : 200,
            headers: [HTTPField("Set-Cookie", "a=1"), HTTPField("Set-Cookie", "b=2")], url: request.url,
            readBody: { [self] in try await body(request.url, control: control) }, cancel: {
                let first = cancelled.withLock { value in let first = !value; value = true; return first }
                if first { cancelCount.withLock { $0 += 1 } }
            })
    }
    private func body(_ url: String, control: ScriptExecutionControl) async throws -> Data {
        state.reads += 1
        if url.contains("brokenBody") { throw WorkflowError.invalid("broken response body") }
        if url.contains("bodyWait") {
            while !control.isCancelled { try await Task.sleep(for: .milliseconds(20)) }
            try control.check()
        }
        if url.contains("large") { return Data(String(repeating: "字😀", count: 100_000).utf8) }
        if url.contains("binary") { return Data([0,255,1]) }
        return Data(#"{"token":"令牌"}"#.utf8)
    }
}
