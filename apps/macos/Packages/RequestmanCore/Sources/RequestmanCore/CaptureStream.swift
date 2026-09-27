import Foundation
import os

public enum CaptureProtocol: String, Codable, Sendable { case http = "HTTP", sse = "SSE", webSocket = "WebSocket" }
public enum CaptureConnectionState: String, Codable, Sendable {
    case connecting = "连接中", open = "接收中", closed = "已关闭", failed = "失败"
    public var isActive: Bool { self == .connecting || self == .open }
}

public struct CaptureStreamMessage: Codable, Sendable, Identifiable {
    public enum Direction: String, Codable, Sendable { case received = "接收", sent = "发送" }
    public let id: Int
    public let date: Date
    public let direction: Direction
    public let kind: String
    public let eventID: String?
    public let data: Data
    public var text: String {
        if kind == "Close", data.count >= 2 {
            let code = UInt16(data[data.startIndex]) << 8 | UInt16(data[data.startIndex + 1])
            return "\(code) " + String(decoding: data.dropFirst(2), as: UTF8.self)
        }
        if kind != "二进制", let text = String(data: data, encoding: .utf8) { return text }
        return data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
    public init(id: Int = 0, date: Date = Date(), direction: Direction = .received, kind: String,
                eventID: String? = nil, data: Data) {
        self.id = id; self.date = date; self.direction = direction; self.kind = kind; self.eventID = eventID; self.data = data
    }
}

/// Incremental WHATWG event-stream parser. Network chunks are not event boundaries.
public struct SSEParser: Sendable {
    private var line = Data()
    private var afterCR = false
    private var firstLine = true
    private var data = ""
    private var event = ""
    private var lastEventID = ""
    public private(set) var retryMilliseconds: UInt64?
    public init() {}
    public mutating func append(_ bytes: Data, emit: (String, String, Data) -> Void) {
        for byte in bytes {
            if afterCR { afterCR = false; if byte == 10 { continue } }
            if byte == 10 || byte == 13 {
                processLine(emit: emit); afterCR = byte == 13
            } else { line.append(byte) }
        }
    }
    private mutating func processLine(emit: (String, String, Data) -> Void) {
        var text = String(decoding: line, as: UTF8.self); line.removeAll(keepingCapacity: true)
        if firstLine { firstLine = false; if text.hasPrefix("\u{feff}") { text.removeFirst() } }
        if text.isEmpty {
            if !data.isEmpty { data.removeLast(); emit(event.isEmpty ? "message" : event, lastEventID, Data(data.utf8)) }
            data = ""; event = ""; return
        }
        if text.hasPrefix(":") { return }
        let colon = text.firstIndex(of: ":")
        let name = colon.map { String(text[..<$0]) } ?? text
        var value = colon.map { String(text[text.index(after: $0)...]) } ?? ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch name {
        case "data": data += value + "\n"
        case "event": event = value
        case "id": if !value.contains("\0") { lastEventID = value }
        case "retry": if !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) { retryMilliseconds = UInt64(value) }
        default: break
        }
    }
}

/// Session-only append store. Disk work and parsing are confined to one serial queue.
/// Callers wait for append completion before reading the next network batch; no unbounded write queue.
/// Only offsets live in memory; full payloads and original SSE bytes remain on disk until the last owner releases them.
public final class CaptureStreamStore: @unchecked Sendable {
    public struct Summary: Codable, Sendable {
        public var count = 0
        public var bytes = 0
        public var revision = 0
        public var error: String?
    }
    private let queue = DispatchQueue(label: "app.requestman.stream-store", qos: .utility)
    private let summaryState = OSAllocatedUnfairLock(initialState: Summary())
    private var directory: URL?
    private var messages: FileHandle?
    private var raw: FileHandle?
    private var offsets: [(UInt64, Int)] = []
    private var position: UInt64 = 0
    private var parser = SSEParser()
    private let contentEncoding: String?
    private var decoder: StreamContentDecoder?
    public init(contentEncoding: String? = nil) { self.contentEncoding = contentEncoding }
    public var summary: Summary { summaryState.withLock { $0 } }
    deinit {
        let messages = messages, raw = raw, directory = directory
        DispatchQueue.global(qos: .utility).async {
            try? messages?.close(); try? raw?.close()
            if let directory { _ = try? FileManager.default.trashItem(at: directory, resultingItemURL: nil) }
        }
    }
    private func prepare() throws {
        guard directory == nil else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("requestman-stream-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        directory = folder
        let messageURL = folder.appendingPathComponent("messages"), rawURL = folder.appendingPathComponent("raw")
        guard FileManager.default.createFile(atPath: messageURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              FileManager.default.createFile(atPath: rawURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        messages = try FileHandle(forUpdating: messageURL); raw = try FileHandle(forUpdating: rawURL)
    }
    public func appendSSE(_ bytes: Data, decoded: Data? = nil, date: Date = Date(), completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            defer { completion() }
            guard summary.error == nil else { return }
            do {
                try prepare(); try raw?.seekToEnd(); try raw?.write(contentsOf: bytes)
                if decoder == nil { decoder = try StreamContentDecoder(encoding: contentEncoding) }
                var events: [(String, String, Data)] = []
                parser.append(try decoded ?? decoder!.append(bytes)) { events.append(($0, $1, $2)) }
                for event in events { try write(CaptureStreamMessage(date: date, kind: event.0, eventID: event.1, data: event.2)) }
                summaryState.withLock { $0.bytes += bytes.count; $0.revision += 1 }
            } catch { recordError(error.localizedDescription) }
        }
    }
    public func append(_ message: CaptureStreamMessage, completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            defer { completion() }
            guard summary.error == nil else { return }
            do {
                try prepare(); try write(message)
                summaryState.withLock { $0.bytes += message.data.count; $0.revision += 1 }
            } catch { recordError(error.localizedDescription) }
        }
    }
    public func recordError(_ description: String) {
        summaryState.withLock { if $0.error == nil { $0.error = description; $0.revision += 1 } }
    }
    private func write(_ message: CaptureStreamMessage) throws {
        let message = CaptureStreamMessage(id: offsets.count, date: message.date, direction: message.direction,
                                           kind: message.kind, eventID: message.eventID, data: message.data)
        let bytes = try JSONEncoder().encode(message)
        try messages?.seek(toOffset: position)
        try messages?.write(contentsOf: bytes)
        offsets.append((position, bytes.count)); position += UInt64(bytes.count)
        summaryState.withLock { $0.count = offsets.count }
    }
    public func read(from start: Int, limit: Int = 200) async throws -> [CaptureStreamMessage] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard let messages else { continuation.resume(returning: []); return }
                    var result: [CaptureStreamMessage] = []
                    let lower = min(max(0, start), offsets.count)
                    let upper = lower + min(max(0, limit), offsets.count - lower)
                    for index in lower..<upper {
                        let (offset, count) = offsets[index]
                        try messages.seek(toOffset: offset)
                        guard let data = try messages.read(upToCount: count), data.count == count else { throw CocoaError(.fileReadCorruptFile) }
                        result.append(try JSONDecoder().decode(CaptureStreamMessage.self, from: data))
                    }
                    try messages.seekToEnd()
                    continuation.resume(returning: result)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    public func readRaw(from offset: UInt64, limit: Int = 65_536) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard let raw else { continuation.resume(returning: Data()); return }
                    try raw.seek(toOffset: offset)
                    let bytes = try raw.read(upToCount: max(1, limit)) ?? Data()
                    try raw.seekToEnd(); continuation.resume(returning: bytes)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    public func flush(_ completion: @escaping @Sendable () -> Void) { queue.async(execute: completion) }
}

extension CaptureStreamStore {
    func archiveSnapshot() async throws -> CaptureStreamArchiveSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let rawLength = try raw?.seekToEnd() ?? 0
                    continuation.resume(returning: CaptureStreamArchiveSnapshot(owner: self, directory: directory,
                        summary: summary, messageLengths: offsets.map(\.1), rawLength: rawLength))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Called only before publication, on the archive reader's background task.
    static func restoreArchive(_ archive: RequestLogArchive.ArchiveStream) throws -> CaptureStreamStore {
        guard archive.summary.count == archive.messages.count, archive.summary.bytes >= 0, archive.summary.revision >= 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let store = CaptureStreamStore()
        try store.prepare()
        for (index, entry) in archive.messages.enumerated() {
            try Task.checkCancellation()
            guard entry.id == index else { throw CocoaError(.fileReadCorruptFile) }
            try store.write(entry.message)
        }
        try store.raw?.write(contentsOf: archive.raw.data)
        store.summaryState.withLock { $0 = archive.summary }
        return store
    }
}
