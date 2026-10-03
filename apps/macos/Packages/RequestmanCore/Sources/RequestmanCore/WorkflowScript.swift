import Darwin
import Foundation
import JavaScriptCore
import os

public struct ScriptOptions: Codable, Equatable, Sendable {
    public var timeoutMilliseconds = 10000
    public init() {}
}

/// Serializable message values; fetch uses a separate host RPC and never exports native objects.
public struct ScriptMessage: Codable, Sendable {
    public var method: String?
    public var url: String?
    public var status: Int?
    public var headers: [HTTPField]
    public var body: String?
    public init(_ draft: HTTPMessageDraft, response: Bool) {
        method = response ? nil : draft.method; url = response ? nil : draft.url
        status = response ? draft.status : nil; headers = draft.headers
        body = draft.replacementBodyData == nil ? (draft.replacementBody ?? draft.bodyText) : nil
    }
    private enum CodingKeys: String, CodingKey { case method, url, status, headers, body }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(method, forKey: .method)
        try values.encodeIfPresent(url, forKey: .url)
        try values.encodeIfPresent(status, forKey: .status)
        try values.encode(headers, forKey: .headers)
        if let body { try values.encode(body, forKey: .body) }
        else { try values.encodeNil(forKey: .body) }
    }

}

private final class ScriptBundleAnchor: NSObject {}

public enum WorkflowScript {
    public static let workerArgument = "--requestman-script-worker"

    /// Compatibility boundary for callers already running on a dedicated background thread.
    /// Production capture and preview use runAsync; no Swift cooperative executor waits on a pipe.
    public static func run(source: String, draft: HTTPMessageDraft, response: Bool,
                           request: HTTPMessageDraft?, environment: [String: String], timeoutMilliseconds: Int,
                           control: ScriptExecutionControl? = nil,
                           environmentTypes: [String: EnvironmentValueType] = [:]) throws -> HTTPMessageDraft {
        let input = try input(source: source, draft: draft, response: response, request: request,
            environment: environment, environmentTypes: environmentTypes, timeout: timeoutMilliseconds)
        let completion = SynchronousScriptResult()
        let session = ScriptWorkerSession(executable: try workerExecutable(), script: input, timeout: timeoutMilliseconds,
            control: control ?? ScriptExecutionControl(), client: nil, parentID: nil, stepID: nil,
            completion: { completion.finish($0) })
        session.start()
        let result = try completion.wait()
        return try output(result, draft: draft, response: response)
    }

    public static func runAsync(source: String, draft: HTTPMessageDraft, response: Bool,
                                request: HTTPMessageDraft?, environment: [String: String], timeoutMilliseconds: Int,
                                control: ScriptExecutionControl? = nil,
                                environmentTypes: [String: EnvironmentValueType] = [:],
                                httpClient: (any ScriptHTTPClient)? = nil,
                                parentTransactionID: UUID? = nil, stepID: UUID? = nil) async throws -> HTTPMessageDraft {
        let input = try input(source: source, draft: draft, response: response, request: request,
            environment: environment, environmentTypes: environmentTypes, timeout: timeoutMilliseconds)
        let executable = try workerExecutable(), control = control ?? ScriptExecutionControl()
        let result: ScriptOutput = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let session = ScriptWorkerSession(executable: executable, script: input, timeout: timeoutMilliseconds,
                    control: control, client: httpClient, parentID: parentTransactionID, stepID: stepID,
                    completion: { continuation.resume(with: $0) })
                session.start()
            }
        } onCancel: { control.cancel() }
        try Task.checkCancellation(); try control.check()
        return try output(result, draft: draft, response: response)
    }

    private static func input(source: String, draft: HTTPMessageDraft, response: Bool, request: HTTPMessageDraft?,
                              environment: [String: String], environmentTypes: [String: EnvironmentValueType],
                              timeout: Int) throws -> ScriptInput {
        guard !source.isEmpty else { throw WorkflowError.invalid("脚本不能为空") }
        guard (50...60000).contains(timeout) else { throw WorkflowError.invalid("脚本超时需在 50–60000 ms 之间") }
        for (name, value) in environment {
            guard (environmentTypes[name] ?? .string).accepts(value) else {
                throw WorkflowError.invalid("环境变量 \(name) 的值与数据类型不符")
            }
        }
        return ScriptInput(source: source, request: ScriptMessage(request ?? draft, response: false),
            response: response ? ScriptMessage(draft, response: true) : nil, env: environment, environmentTypes: environmentTypes)
    }

    private static func output(_ result: ScriptOutput, draft: HTTPMessageDraft, response: Bool) throws -> HTTPMessageDraft {
        if let error = result.error { throw WorkflowError.invalid(error) }
        guard let message = result.message else { throw WorkflowError.invalid("脚本必须返回当前阶段的 request 或 response 对象") }
        return try validated(message, original: draft, response: response)
    }

    private static func workerExecutable() throws -> URL {
        if let executable = Bundle.main.executableURL, Bundle.main.bundleURL.pathExtension == "app" { return executable }
        // SwiftPM builds this standalone worker for package and integration tests.
        for location in [Bundle(for: ScriptBundleAnchor.self).bundleURL, Bundle.main.bundleURL,
                         URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL] {
            var directory = location.deletingLastPathComponent()
            for _ in 0..<7 {
                let candidate = directory.appendingPathComponent("RequestmanScriptWorker")
                if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
                directory.deleteLastPathComponent()
            }
        }
        throw WorkflowError.invalid("找不到脚本执行进程")
    }

    /// Called before constructing NSApplication. One worker owns one VM until the final Promise settles.
    public static func runWorkerIfRequested() -> Bool {
        guard CommandLine.arguments.contains(workerArgument) else { return false }
        do {
            guard let message = try ScriptIPC.read(from: .standardInput), message.kind == "run", let data = message.data else {
                throw WorkflowError.invalid("缺少脚本运行输入")
            }
            try ScriptWorker().run(JSONDecoder().decode(ScriptInput.self, from: data))
        } catch {
            if let data = try? JSONEncoder().encode(ScriptOutput(message: nil, error: error.localizedDescription)) {
                try? ScriptIPC.write(.init(kind: "complete", data: data), to: .standardOutput)
            }
        }
        return true
    }

    private static func validated(_ message: ScriptMessage, original: HTTPMessageDraft, response: Bool) throws -> HTTPMessageDraft {
        var result = original
        for field in message.headers {
            guard HTTPMessageValidation.isToken(field.name), !field.value.utf8.contains(where: { $0 < 32 && $0 != 9 || $0 == 127 }) else {
                throw WorkflowError.invalid("脚本返回了无效 Header")
            }
        }
        // Framing headers may be read, but are owned by the proxy and cannot be changed by a script.
        for name in HTTPMessageValidation.managedHeaders {
            guard message.headers.filter({ $0.name.lowercased() == name }) == original.headers.filter({ $0.name.lowercased() == name }) else {
                throw WorkflowError.invalid("\(name) 由代理自动维护，请修改 url 或 body")
            }
        }
        result.headers = message.headers
        if response {
            guard let status = message.status, (200...599).contains(status) else { throw WorkflowError.invalid("response.status 需在 200–599 之间") }
            result.status = status
        } else {
            guard let method = message.method, HTTPMessageValidation.isToken(method), !["CONNECT", "TRACE"].contains(method.uppercased()),
                  let url = message.url, let parts = URLComponents(string: url), ["http", "https"].contains(parts.scheme),
                  parts.host != nil, parts.user == nil, parts.fragment == nil,
                  !url.utf8.contains(where: { $0 < 32 || $0 == 127 }) else { throw WorkflowError.invalid("脚本请求方法或 URL 无效") }
            result.method = method.uppercased(); result.url = url
        }
        if let body = message.body {
            if original.replacementBodyData != nil || body != (original.replacementBody ?? original.bodyText) {
                result.replacementBody = body
                result.replacementBodyData = nil
                HTTPMessageValidation.clearBodyEncoding(&result)
            }
        }
        return result
    }
}

/// Cancellation callbacks are invoked once, outside the state lock, including late registration.
public final class ScriptExecutionControl: Sendable {
    private struct State: Sendable {
        var cancelled = false
        var handlers: [UUID: @Sendable () -> Void] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    public init() {}
    public var isCancelled: Bool { state.withLock { $0.cancelled } }
    public func cancel() {
        let callbacks = state.withLock { value -> [@Sendable () -> Void] in
            guard !value.cancelled else { return [] }
            value.cancelled = true
            let callbacks = Array(value.handlers.values); value.handlers.removeAll()
            return callbacks
        }
        for callback in callbacks { callback() }
    }
    @discardableResult public func addCancellationHandler(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        let invoke = state.withLock { value in
            if value.cancelled { return true }
            value.handlers[id] = handler; return false
        }
        if invoke { handler() }
        return id
    }
    public func removeCancellationHandler(_ id: UUID) { _ = state.withLock { $0.handlers.removeValue(forKey: id) } }
    public func check() throws { if isCancelled { throw WorkflowError.invalid("流程已取消") } }
}

private final class SynchronousScriptResult: Sendable {
    private let value = OSAllocatedUnfairLock<Result<ScriptOutput, any Error>?>(initialState: nil)
    private let completed = DispatchSemaphore(value: 0)
    func finish(_ result: Result<ScriptOutput, any Error>) { value.withLock { $0 = result }; completed.signal() }
    func wait() throws -> ScriptOutput { completed.wait(); return try value.withLock { try $0!.get() } }
}
