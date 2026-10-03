import Foundation
import NIOCore
import RequestmanCore
import os

/// The body can outlive the socket operation; per-call abort must still interrupt decoding after EOF.
final class ScriptHTTPBodyControl: Sendable {
    let control: ScriptExecutionControl
    private let parent: ScriptExecutionControl
    private let cancellationID: UUID
    init(parent: ScriptExecutionControl) {
        let control = ScriptExecutionControl()
        self.control = control; self.parent = parent
        cancellationID = parent.addCancellationHandler { control.cancel() }
    }
    deinit { parent.removeCancellationHandler(cancellationID) }
}

/// A finite admission queue, independent of the number of Promises created by one script.
actor ScriptHTTPAdmission {
    static let shared = ScriptHTTPAdmission()
    private let maximumActive: Int
    private let maximumWaiting: Int
    private var active = 0
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var waiting: [Waiter] = []
    var queuedCount: Int { waiting.count }
    init(maximumActive: Int = 8, maximumWaiting: Int = 64) {
        self.maximumActive = max(1, maximumActive); self.maximumWaiting = max(0, maximumWaiting)
    }
    func acquire(control: ScriptExecutionControl) async throws -> ScriptHTTPPermit {
        try control.check()
        let id = UUID()
        let cancellation = control.addCancellationHandler { Task { await self.cancel(id) } }
        defer { control.removeCancellationHandler(cancellation) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if control.isCancelled || Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                if active < maximumActive { active += 1; continuation.resume(); return }
                guard waiting.count < maximumWaiting else {
                    continuation.resume(throwing: WorkflowError.invalid("fetch 等待队列已满")); return
                }
                waiting.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: { Task { await self.cancel(id) } }
        return ScriptHTTPPermit(admission: self)
    }
    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }
    fileprivate func release() {
        if waiting.isEmpty { active -= 1 }
        else { waiting.removeFirst().continuation.resume() }
    }
}

final class ScriptHTTPPermit: Sendable {
    private let admission: ScriptHTTPAdmission
    private let released = OSAllocatedUnfairLock(initialState: false)
    init(admission: ScriptHTTPAdmission) { self.admission = admission }
    func release() {
        let first = released.withLock { value in guard !value else { return false }; value = true; return true }
        if first { let admission = admission; Task { await admission.release() } }
    }
    deinit { release() }
}

/// File I/O is serialized off NIO. The next socket read waits for the last append to finish.
final class ScriptHTTPBodyStorage: @unchecked Sendable {
    struct StoredBody: Sendable { let bytes: Data; let error: (any Error)? }
    private let queue = DispatchQueue(label: "Requestman.ScriptHTTP.Body", qos: .utility)
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("requestman-fetch-\(UUID().uuidString).body")
    private var writer: FileHandle?
    private var failure: (any Error)?
    private var closed = false
    func append(_ bytes: Data, on eventLoop: any EventLoop) -> EventLoopFuture<Void> {
        let promise = eventLoop.makePromise(of: Void.self)
        queue.async { [self] in
            do {
                if let failure { throw failure }
                guard !closed else { throw WorkflowError.invalid("fetch 正文存储已关闭") }
                if writer == nil {
                    guard FileManager.default.createFile(atPath: url.path, contents: nil,
                        attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
                    writer = try FileHandle(forWritingTo: url)
                }
                try writer?.write(contentsOf: bytes)
                promise.succeed(())
            } catch { failure = error; promise.fail(error) }
        }
        return promise.futureResult
    }
    func finish(on eventLoop: any EventLoop) -> EventLoopFuture<StoredBody> {
        let promise = eventLoop.makePromise(of: StoredBody.self)
        queue.async { [self] in
            closed = true
            do { try writer?.close() } catch { if failure == nil { failure = error } }
            writer = nil
            do {
                let data = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : Data()
                promise.succeed(StoredBody(bytes: data, error: failure))
            } catch { promise.fail(error) }
        }
        return promise.futureResult
    }
    deinit {
        let url = url, writer = writer
        queue.async {
            try? writer?.close()
            if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        }
    }
}
