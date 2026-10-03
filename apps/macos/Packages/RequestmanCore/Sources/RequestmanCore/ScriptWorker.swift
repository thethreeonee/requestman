import Foundation
import JavaScriptCore

/// JSContext and every Promise callback remain on the worker's initial thread/run loop.
final class ScriptWorker: @unchecked Sendable {
    private let loop = CFRunLoopGetCurrent()!
    private let context = JSContext()!
    private var receiver: JSValue?
    private var completed = false
    private var drained = false
    private let writes = DispatchQueue(label: "requestman.script.worker.protocol")
    private let writePermits = DispatchSemaphore(value: 72)

    func run(_ input: ScriptInput) throws {
        let keepAlive = Timer(timeInterval: 3600, repeats: true) { _ in }
        RunLoop.current.add(keepAlive, forMode: .default)
        defer { keepAlive.invalidate() }
        let finishCallback: @convention(block) (JSValue?, JSValue?) -> Void = { [weak self] value, error in
            let text: (JSValue?) -> String? = { value in
                guard let value, !value.isNull, !value.isUndefined else { return nil }
                return value.toString()
            }
            self?.finish(value: text(value), error: text(error))
        }
        let bridge: @convention(block) (String, String?) -> String = { [weak self] kind, json in
            guard let self else { return "" }
            let id: UUID
            var data: Data?
            if kind == "fetch" {
                id = UUID(); data = json.map { Data($0.utf8) }
            } else {
                guard let json, let parsed = UUID(uuidString: json) else { return "" }
                id = parsed
            }
            guard self.send(.init(kind: kind, id: id, data: data)) else { return "" }
            return id.uuidString
        }
        context.setObject(finishCallback, forKeyedSubscript: "__finish" as NSString)
        context.setObject(bridge, forKeyedSubscript: "__bridge" as NSString)
        context.setObject(try JSONSerialization.jsonObject(with: JSONEncoder().encode(input)), forKeyedSubscript: "__input" as NSString)
        receiver = context.evaluateScript(Self.bootstrap)
        if let exception = context.exception { finish(value: nil, error: exception.toString()) }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                while let message = try ScriptIPC.read(from: .standardInput) {
                    let handled = DispatchSemaphore(value: 0)
                    CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [self] in
                        receive(message); handled.signal()
                    }
                    CFRunLoopWakeUp(loop)
                    // Bound the run-loop mailbox to one message. This is a Dispatch pipe reader.
                    handled.wait()
                }
                CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [self] in
                    if !completed { finish(value: nil, error: "脚本宿主连接已关闭") }
                }
                CFRunLoopWakeUp(loop)
            } catch {
                let description = error.localizedDescription
                CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [self] in finish(value: nil, error: description) }
                CFRunLoopWakeUp(loop)
            }
        }
        while !drained { CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.1, true) }
    }
    private func receive(_ message: ScriptIPCMessage) {
        guard !completed else { return }
        receiver?.call(withArguments: [message.kind, message.id?.uuidString ?? "", message.data?.base64EncodedString() ?? "", message.error ?? ""])
        if let exception = context.exception { finish(value: nil, error: exception.toString()) }
    }
    private func send(_ message: ScriptIPCMessage) -> Bool {
        guard writePermits.wait(timeout: .now()) == .success else { return false }
        writes.async { [self] in
            defer { writePermits.signal() }
            try? ScriptIPC.write(message, to: .standardOutput)
        }
        return true
    }
    private func finish(value: String?, error: String?) {
        guard !completed else { return }
        completed = true
        let output: ScriptOutput
        do { output = ScriptOutput(message: try value.map { try JSONDecoder().decode(ScriptMessage.self, from: Data($0.utf8)) }, error: error) }
        catch { output = ScriptOutput(message: nil, error: error.localizedDescription) }
        let data = try? JSONEncoder().encode(output)
        writes.async { [self] in
            if let data { try? ScriptIPC.write(.init(kind: "complete", data: data), to: .standardOutput) }
            CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [self] in drained = true }
            CFRunLoopWakeUp(loop)
        }
        receiver = nil
    }
}
