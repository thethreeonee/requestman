import Darwin
import Foundation
import JavaScriptCore
import os

public struct ScriptOptions: Codable, Equatable, Sendable {
    public var timeoutMilliseconds = 1000
    public init() {}
}

/// Serializable values only: no native object, file, network or process API is exported to JavaScript.
public struct ScriptMessage: Codable, Sendable {
    public var method: String?
    public var url: String?
    public var status: Int?
    public var headers: [HTTPField]
    public var body: String?
    public init(_ draft: HTTPMessageDraft, response: Bool) {
        method = response ? nil : draft.method; url = response ? nil : draft.url
        status = response ? draft.status : nil; headers = draft.headers
        body = draft.replacementBody ?? draft.bodyText
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

private struct ScriptInput: Codable {
    let source: String
    let request: ScriptMessage
    let response: ScriptMessage?
    let env: [String: String]
}

private struct ScriptOutput: Codable {
    let message: ScriptMessage?
    let error: String?
}

private final class ScriptBundleAnchor: NSObject {}

public enum WorkflowScript {
    private static let slots = DispatchSemaphore(value: 4)
    public static let workerArgument = "--requestman-script-worker"

    /// Synchronous by design; callers execute on a bounded background queue, never on the UI/NIO loop.
    public static func run(source: String, draft: HTTPMessageDraft, response: Bool,
                           request: HTTPMessageDraft?, environment: [String: String], timeoutMilliseconds: Int, control: ScriptExecutionControl? = nil) throws -> HTTPMessageDraft {
        guard !source.isEmpty else { throw WorkflowError.invalid("脚本不能为空") }
        try control?.check()
        guard (50...5000).contains(timeoutMilliseconds) else { throw WorkflowError.invalid("脚本超时需在 50–5000 ms 之间") }
        guard slots.wait(timeout: .now()) == .success else { throw WorkflowError.invalid("脚本执行已满，请稍后重试") }
        defer { slots.signal() }
        let input = ScriptInput(source: source, request: ScriptMessage(request ?? draft, response: false),
                                response: response ? ScriptMessage(draft, response: true) : nil, env: environment)
        let data = try JSONEncoder().encode(input)
        let process = Process()
        process.executableURL = try workerExecutable()
        process.arguments = [workerArgument]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        try process.run()
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL); completed.wait() }
        }
        let deadline = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(timeoutMilliseconds), execute: deadline)
        let cancellation = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        cancellation.schedule(deadline: .now(), repeating: .milliseconds(25))
        cancellation.setEventHandler {
            if control?.isCancelled == true, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        cancellation.resume()
        defer { deadline.cancel(); cancellation.cancel(); try? stdout.fileHandleForReading.close() }
        DispatchQueue.global(qos: .userInitiated).async {
            try? stdin.fileHandleForWriting.write(contentsOf: data)
            try? stdin.fileHandleForWriting.close()
        }
        var output = Data()
        while let chunk = try stdout.fileHandleForReading.read(upToCount: 16_384), !chunk.isEmpty {
            output.append(chunk)
        }
        completed.wait()
        try control?.check()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw WorkflowError.invalid("脚本超时或执行进程已终止")
        }
        let result = try JSONDecoder().decode(ScriptOutput.self, from: output)
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

    /// Called before constructing the App. Each invocation handles exactly one script and exits.
    public static func runWorkerIfRequested() -> Bool {
        guard CommandLine.arguments.contains(workerArgument) else { return false }
        let result: ScriptOutput
        do {
            let data = try FileHandle.standardInput.read(upToCount: 16_384) ?? Data()
            // Drain every chunk: a pipe read may return only part of the JSON message.
            var inputData = data
            while let chunk = try FileHandle.standardInput.read(upToCount: 16_384), !chunk.isEmpty {
                inputData.append(chunk)
            }
            let input = try JSONDecoder().decode(ScriptInput.self, from: inputData)
            result = try evaluate(input)
        } catch { result = ScriptOutput(message: nil, error: error.localizedDescription) }
        if let output = try? JSONEncoder().encode(result) { try? FileHandle.standardOutput.write(contentsOf: output) }
        return true
    }

    private static func evaluate(_ input: ScriptInput) throws -> ScriptOutput {
        guard let context = JSContext() else { throw WorkflowError.invalid("无法创建 JavaScript 环境") }
        let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input))
        context.setObject(payload, forKeyedSubscript: "__input" as NSString)
        // JSON serialization stays inside the disposable process: hostile getters/toJSON cannot hang the host.
        let wrapper = #"""
        (() => {
            const { source, request, response = null, env } = __input;
            delete globalThis.__input;
            request.body ??= null;
            if (response) response.body ??= null;
            const freeze = value => {
                if (value && typeof value === 'object') {
                    Object.values(value).forEach(freeze); Object.freeze(value);
                }
                return value;
            };
            freeze(env);
            if (response) freeze(request);
            const result = new Function('request', 'response', 'env', '"use strict";\n' + source)(request, response, env);
            if (!result || typeof result !== 'object' || typeof result.then === 'function')
                throw new Error('请同步返回当前阶段的 request 或 response 对象；不支持 Promise');
            if (!Array.isArray(result.headers))
                throw new Error('headers 必须是 { name, value } 数组');
            if (result.body !== null && typeof result.body !== 'string')
                throw new Error('body 必须是 UTF-8 文本字符串或 null');
            for (const header of result.headers) {
                if (!header || typeof header.name !== 'string' || typeof header.value !== 'string')
                    throw new Error('每个 Header 必须包含字符串 name 和 value');
            }
            if (response) {
                if (!Number.isInteger(result.status)) throw new Error('response.status 必须是整数');
            } else if (typeof result.method !== 'string' || typeof result.url !== 'string') {
                throw new Error('request.method 和 request.url 必须是字符串');
            }
            return JSON.stringify(response
                ? { status: result.status, headers: result.headers, body: result.body }
                : { method: result.method, url: result.url, headers: result.headers, body: result.body });
        })()
        """#
        let value = context.evaluateScript(wrapper)
        if let exception = context.exception { return ScriptOutput(message: nil, error: exception.toString()) }
        guard let text = value?.toString() else { throw WorkflowError.invalid("脚本返回值无效") }
        return ScriptOutput(message: try JSONDecoder().decode(ScriptMessage.self, from: Data(text.utf8)), error: nil)
    }

    private static func validated(_ message: ScriptMessage, original: HTTPMessageDraft, response: Bool) throws -> HTTPMessageDraft {
        var result = original
        for field in message.headers {
            guard WorkflowEngine.isToken(field.name), !field.value.utf8.contains(where: { $0 < 32 && $0 != 9 || $0 == 127 }) else {
                throw WorkflowError.invalid("脚本返回了无效 Header")
            }
        }
        // Framing headers may be read, but are owned by the proxy and cannot be changed by a script.
        for name in WorkflowEngine.managedHeaders {
            guard message.headers.filter({ $0.name.lowercased() == name }) == original.headers.filter({ $0.name.lowercased() == name }) else {
                throw WorkflowError.invalid("\(name) 由代理自动维护，请修改 url 或 body")
            }
        }
        result.headers = message.headers
        if response {
            guard let status = message.status, (200...599).contains(status) else { throw WorkflowError.invalid("response.status 需在 200–599 之间") }
            result.status = status
        } else {
            guard let method = message.method, WorkflowEngine.isToken(method), !["CONNECT", "TRACE"].contains(method.uppercased()),
                  let url = message.url, let parts = URLComponents(string: url), ["http", "https"].contains(parts.scheme),
                  parts.host != nil, parts.user == nil, parts.fragment == nil,
                  !url.utf8.contains(where: { $0 < 32 || $0 == 127 }) else { throw WorkflowError.invalid("脚本请求方法或 URL 无效") }
            result.method = method.uppercased(); result.url = url
        }
        if let body = message.body {
            if body != (original.replacementBody ?? original.bodyText) {
                result.replacementBody = body
                WorkflowEngine.clearBodyEncoding(&result)
            }
        }
        return result
    }
}

/// Cancellation and the transaction deadline follow the worker even after the socket closes.
public final class ScriptExecutionControl: Sendable {
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    private let deadline: ContinuousClock.Instant
    public init(deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(30))) { self.deadline = deadline }
    public var isCancelled: Bool { cancelled.withLock { $0 } || ContinuousClock.now >= deadline }
    public func cancel() { cancelled.withLock { $0 = true } }
    public func check() throws { if isCancelled { throw WorkflowError.invalid("脚本流程已取消或超过事务时限") } }
}
