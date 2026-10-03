import Darwin
import Foundation
import os

/// Blocking pipe operations live on Dispatch queues; Swift tasks wait only on a continuation.
final class ScriptWorkerSession: @unchecked Sendable {
    private static let slots = DispatchSemaphore(value: 4)
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private let writes = DispatchQueue(label: "requestman.script.worker.write")
    private let stopped = OSAllocatedUnfairLock(initialState: false)
    private let control: ScriptExecutionControl
    private let timeout: Int
    private let executable: URL
    private let script: ScriptInput
    private let client: (any ScriptHTTPClient)?
    private let parentID: UUID?
    private let stepID: UUID?
    private let completion: @Sendable (Result<ScriptOutput, any Error>) -> Void

    init(executable: URL, script: ScriptInput, timeout: Int, control: ScriptExecutionControl,
         client: (any ScriptHTTPClient)?, parentID: UUID?, stepID: UUID?,
         completion: @escaping @Sendable (Result<ScriptOutput, any Error>) -> Void) {
        self.executable = executable; self.script = script; self.timeout = timeout; self.control = control
        self.client = client; self.parentID = parentID; self.stepID = stepID; self.completion = completion
    }

    func start() { DispatchQueue.global(qos: .userInitiated).async { self.execute() } }
    private func stop() {
        let first = stopped.withLock { value in let first = !value; value = true; return first }
        if first, process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    private func send(_ message: ScriptIPCMessage) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            writes.async { [self] in
                guard !stopped.withLock({ $0 }) else { continuation.resume(throwing: CancellationError()); return }
                do {
                    try ScriptIPC.write(message, to: input.fileHandleForWriting)
                    continuation.resume()
                } catch {
                    // A valid completed worker can close stdin before unawaited HTTP replies arrive.
                    // The protocol reader/exit status decides success; a failed late write cannot override it.
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func execute() {
        guard Self.slots.wait(timeout: .now()) == .success else {
            completion(.failure(WorkflowError.invalid("脚本执行已满，请稍后重试"))); return
        }
        let broker = ScriptHTTPBroker(client: client, parentID: parentID, stepID: stepID, send: { [weak self] message in
            guard let self else { throw CancellationError() }
            try await self.send(message)
        })
        var result: Result<ScriptOutput, any Error>
        var deadline: DispatchWorkItem?
        var handler: UUID?
        do {
            try control.check()
            process.executableURL = executable; process.arguments = [WorkflowScript.workerArgument]
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            handler = control.addCancellationHandler { [weak self, weak broker] in
                self?.stop()
                Task { await broker?.shutdown() }
            }
            let timer = DispatchWorkItem { [weak self, weak broker] in
                self?.stop()
                Task { await broker?.shutdown() }
            }
            deadline = timer
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(timeout), execute: timer)
            // Cancellation can race process.run(); the handler and this second check cover both sides.
            try control.check()
            let run = ScriptIPCMessage(kind: "run", data: try JSONEncoder().encode(script))
            Task { try? await send(run) }
            var final: ScriptOutput?
            while let message = try ScriptIPC.read(from: output.fileHandleForReading) {
                switch message.kind {
                case "complete":
                    guard final == nil, let data = message.data else { throw WorkflowError.invalid("脚本重复或缺少运行结果") }
                    final = try JSONDecoder().decode(ScriptOutput.self, from: data)
                case "fetch", "body", "abort":
                    guard final == nil else { throw WorkflowError.invalid("脚本完成后继续调用网络") }
                    // This reader is a Dispatch worker. Only one RPC can await broker admission.
                    let admitted = DispatchSemaphore(value: 0)
                    Task { await broker.receive(message); admitted.signal() }
                    admitted.wait()
                default: throw WorkflowError.invalid("未知脚本通信消息")
                }
            }
            process.waitUntilExit()
            try control.check()
            guard !stopped.withLock({ $0 }), process.terminationReason == .exit, process.terminationStatus == 0,
                  let final else { throw WorkflowError.invalid("脚本超时或执行进程已终止") }
            result = .success(final)
        } catch { result = .failure(error) }
        stop()
        if process.isRunning { process.waitUntilExit() }
        deadline?.cancel()
        if let handler { control.removeCancellationHandler(handler) }
        try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
        let completedResult = result
        Task {
            await broker.shutdown()
            Self.slots.signal()
            completion(completedResult)
        }
    }
}

actor ScriptHTTPBroker {
    private enum Operation: Sendable { case send(ScriptHTTPRequest), body(ScriptHTTPResponse) }
    private let client: (any ScriptHTTPClient)?
    private let parentID: UUID?, stepID: UUID?
    private let executionID = UUID()
    private let send: @Sendable (ScriptIPCMessage) async throws -> Void
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var pending: [(UUID, Operation)] = []
    private var responses: [UUID: ScriptHTTPResponse] = [:]
    private var controls: [UUID: ScriptExecutionControl] = [:]
    private var stopped = false

    init(client: (any ScriptHTTPClient)?, parentID: UUID?, stepID: UUID?,
         send: @escaping @Sendable (ScriptIPCMessage) async throws -> Void) {
        self.client = client; self.parentID = parentID; self.stepID = stepID; self.send = send
    }
    func receive(_ message: ScriptIPCMessage) async {
        guard !stopped, let id = message.id else { return }
        do {
            switch message.kind {
            case "fetch":
                guard client != nil else { throw WorkflowError.invalid("当前运行不允许辅助网络请求") }
                guard tasks[id] == nil, controls[id] == nil, responses[id] == nil else {
                    throw WorkflowError.invalid("重复的辅助请求身份")
                }
                guard responses.count + controls.count < 64, let data = message.data else {
                    throw WorkflowError.invalid("辅助请求数量已满")
                }
                let request = try JSONDecoder().decode(ScriptHTTPRequest.self, from: data)
                try validate(request)
                controls[id] = ScriptExecutionControl()
                try enqueue(id, .send(request))
            case "body":
                guard let response = responses.removeValue(forKey: id) else { throw WorkflowError.invalid("响应正文不可用或已读取") }
                do { try enqueue(id, .body(response)) }
                catch { response.cancel(); throw error }
            case "abort":
                controls.removeValue(forKey: id)?.cancel()
                tasks[id]?.cancel()
                if let index = pending.firstIndex(where: { $0.0 == id }) {
                    if case .body(let response) = pending[index].1 { response.cancel() }
                    pending.remove(at: index)
                }
                responses.removeValue(forKey: id)?.cancel()
                try await send(.init(kind: "error", id: id, error: "AbortError: 请求已取消"))
                pump()
            default: break
            }
        } catch {
            controls.removeValue(forKey: id)?.cancel()
            try? await send(.init(kind: "error", id: id, error: error.localizedDescription))
        }
    }
    private func enqueue(_ id: UUID, _ operation: Operation) throws {
        guard pending.count < 32 else { throw WorkflowError.invalid("辅助请求等待队列已满") }
        pending.append((id, operation)); pump()
    }
    private func pump() {
        while !stopped, tasks.count < 4,
              let index = pending.firstIndex(where: { tasks[$0.0] == nil }) {
            // Header writes can suspend after publishing a response. Its body RPC must wait
            // for that same call's send task to finish without blocking other call identities.
            let (id, operation) = pending.remove(at: index)
            tasks[id] = Task { await perform(id, operation) }
        }
    }
    private func perform(_ id: UUID, _ operation: Operation) async {
        defer { tasks.removeValue(forKey: id); pump() }
        do {
            guard let control = controls[id], !stopped else { return }
            try control.check()
            switch operation {
            case .send(let request):
                guard let client else { return }
                let response = try await client.send(request, context: .init(executionID: executionID,
                    callID: UUID(), parentTransactionID: parentID, stepID: stepID), control: control)
                guard !stopped, !control.isCancelled, controls[id] === control else { response.cancel(); return }
                responses[id] = response
                let metadata = ScriptHTTPMetadata(status: response.status, statusText: response.statusText,
                    headers: response.headers, url: response.url, redirected: response.redirected)
                try await send(.init(kind: "headers", id: id, data: try JSONEncoder().encode(metadata)))
            case .body(let response):
                defer { response.cancel() }
                let data = try await response.readBody()
                try control.check()
                guard !stopped else { return }
                for offset in stride(from: 0, to: data.count, by: 16_384) {
                    try Task.checkCancellation(); try control.check()
                    try await send(.init(kind: "bodyChunk", id: id, data: data.subdata(in: offset..<min(data.count, offset + 16_384))))
                }
                try await send(.init(kind: "bodyEnd", id: id))
                controls.removeValue(forKey: id)
            }
        } catch {
            guard !stopped, controls[id] != nil else { return }
            controls.removeValue(forKey: id)?.cancel()
            try? await send(.init(kind: "error", id: id, error: error.localizedDescription))
        }
    }
    func shutdown() {
        stopped = true
        for control in controls.values { control.cancel() }
        for task in tasks.values { task.cancel() }
        for response in responses.values { response.cancel() }
        for (_, operation) in pending { if case .body(let response) = operation { response.cancel() } }
        controls.removeAll(); responses.removeAll(); pending.removeAll(); tasks.removeAll()
    }
    private func validate(_ request: ScriptHTTPRequest) throws {
        guard let url = URLComponents(string: request.url), ["http", "https"].contains(url.scheme),
              url.host != nil, url.user == nil, url.password == nil, url.fragment == nil,
              HTTPMessageValidation.isToken(request.method),
              !["CONNECT", "TRACE", "TRACK"].contains(request.method.uppercased()),
              !["GET", "HEAD"].contains(request.method.uppercased()) || request.body == nil else {
            throw WorkflowError.invalid("fetch URL、方法或正文无效")
        }
        for field in request.headers {
            guard HTTPMessageValidation.isToken(field.name),
                  !field.value.utf8.contains(where: { $0 < 32 && $0 != 9 || $0 == 127 }),
                  !HTTPMessageValidation.managedHeaders.contains(field.name.lowercased()) else {
                throw WorkflowError.invalid("fetch Header 无效或由宿主管理：\(field.name)")
            }
        }
    }
}
