import Foundation
import Darwin

/// UTF-8 JSON, independent of the workspace configuration archive. All file I/O runs off the main actor.
public enum RequestLogArchive {
    public static let fileExtension = "json"
    public static let filenameSuffix = ".requestmanlog.json"
    struct Header: Codable {
        var format = "requestman.log"
        var version = 1
        var savedAt: Date
        var fieldGuide: [String: String] = [
            "requestHeaders / requestBody": "客户端发出的原始请求",
            "sentHeaders / sentBody": "经过规则处理后发往服务器的请求",
            "receivedHeaders / receivedBody": "服务器返回的原始响应",
            "responseHeaders / responseBody": "经过规则处理后返回客户端的响应",
            "duration": "总耗时，单位：秒",
            "payload.text / payload.base64": "原始正文的 UTF-8 文本或 Base64；两者只保存一种",
            "decodedText": "压缩正文解码后的阅读副本，原始字节仍保存在 payload 中",
            "sharedStream": "为 true 时，receivedStream 与 stream 内容相同",
            "connectionState": "保存时的连接状态，打开文件不会恢复连接",
            "auxiliaryParentID / auxiliaryStepID": "脚本辅助请求关联的父请求与步骤；真实联调可没有父请求",
            "auxiliaryCallID / auxiliaryExecutionID": "辅助请求调用和脚本执行标识，不参与规则匹配"
        ]
    }
    struct Document: Decodable {
        var format: String
        var version: Int
        var savedAt: Date
        var records: [Entry]
    }
    struct Entry: Codable {
        var record: CaptureRecord
        var stream: ArchiveStream?
        var receivedStream: ArchiveStream?
        var sharedStream: Bool
    }
    struct ArchiveMessage: Codable {
        let id: Int
        let date: Date
        let direction: CaptureStreamMessage.Direction
        let kind: String
        let eventID: String?
        let payload: LogPayload
        init(_ message: CaptureStreamMessage) {
            id = message.id; date = message.date; direction = message.direction
            kind = message.kind; eventID = message.eventID; payload = LogPayload(message.data)
        }
        var message: CaptureStreamMessage {
            CaptureStreamMessage(id: id, date: date, direction: direction, kind: kind, eventID: eventID, data: payload.data)
        }
    }
    struct ArchiveStream: Codable {
        var summary: CaptureStreamStore.Summary
        var messages: [ArchiveMessage]
        var raw: LogPayload
    }
    public struct Contents: Sendable {
        public let savedAt: Date
        public let records: [CaptureRecord]
    }
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Milliseconds retain capture timestamps while staying readable outside the app.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer()
            try value.encode(date.ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)))
        }
        return encoder
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            return try Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt))
        }
        return decoder
    }

    public static func write(_ records: [CaptureRecord], to url: URL) async throws {
        guard Set(records.map(\.id)).count == records.count else { throw invalid("日志包含重复的请求") }
        // Freeze append boundaries first; ongoing SSE/WS cannot keep extending this export.
        var snapshots: [(CaptureStreamArchiveSnapshot?, CaptureStreamArchiveSnapshot?)] = []
        for record in records {
            try Task.checkCancellation()
            let first = try await record.stream?.archiveSnapshot()
            let second = record.stream != nil && record.stream === record.receivedStream
                ? nil : try await record.receivedStream?.archiveSnapshot()
            snapshots.append((first, second))
        }
        let header = Header(savedAt: Date())
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".requestman-log-\(UUID()).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var installed = false
        defer { if !installed { _ = try? FileManager.default.trashItem(at: temporary, resultingItemURL: nil) } }
        let file = try FileHandle(forWritingTo: temporary)
        do {
            let encoder = encoder()
            // Encode one record at a time instead of materializing every Body/stream in one JSON buffer.
            var prefix = try encoder.encode(header)
            guard prefix.last == UInt8(ascii: "}") else { throw CocoaError(.fileWriteUnknown) }
            prefix.removeLast()
            try file.write(contentsOf: prefix)
            try file.write(contentsOf: Data(",\n\"records\": [\n".utf8))
            for (index, item) in zip(records, snapshots).enumerated() {
                try Task.checkCancellation()
                let (record, pair) = item
                let shared = record.stream != nil && record.stream === record.receivedStream
                let entry = Entry(record: record, stream: try pair.0?.contents(),
                                  receivedStream: try pair.1?.contents(), sharedStream: shared)
                if index > 0 { try file.write(contentsOf: Data(",\n".utf8)) }
                try file.write(contentsOf: encoder.encode(entry))
            }
            try file.write(contentsOf: Data("\n]\n}\n".utf8))
            try file.synchronize(); try file.close()
            try Task.checkCancellation()
            guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            installed = true
        } catch {
            try? file.close()
            throw error
        }
    }

    public static func read(from url: URL) throws -> Contents {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let decoder = decoder()
        let header = try decoder.decode(Header.self, from: data)
        guard header.format == "requestman.log" else { throw invalid("不是 Requestman 日志文件") }
        guard header.version == 1 else { throw invalid("不支持此日志版本（\(header.version)）") }
        let document = try decoder.decode(Document.self, from: data)
        var records: [CaptureRecord] = [], ids: Set<UUID> = []
        for entry in document.records {
            try Task.checkCancellation()
            var record = entry.record
            guard ids.insert(record.id).inserted, record.duration.isFinite, record.duration >= 0, record.duration < Double(Int.max / 1000),
                  record.requestBytes >= 0, record.responseBytes >= 0,
                  !entry.sharedStream || (entry.stream != nil && entry.receivedStream == nil) else {
                throw invalid("日志记录内容无效")
            }
            if let stream = entry.stream { record.stream = try CaptureStreamStore.restoreArchive(stream) }
            if let stream = entry.receivedStream { record.receivedStream = try CaptureStreamStore.restoreArchive(stream) }
            if entry.sharedStream { record.receivedStream = record.stream }
            record.archivedAt = record.archivedAt ?? header.savedAt
            records.append(record)
        }
        return Contents(savedAt: header.savedAt, records: records)
    }
    private static func invalid(_ reason: String) -> WorkflowError { .invalid(reason) }
}

/// Exactly one lossless representation. Text stays readable; binary bytes use explicitly named Base64.
struct LogPayload: Codable, Sendable {
    let data: Data
    init(_ data: Data) { self.data = data }
    private enum CodingKeys: String, CodingKey { case text, base64 }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let text = try values.decodeIfPresent(String.self, forKey: .text)
        let base64 = try values.decodeIfPresent(String.self, forKey: .base64)
        if let text, base64 == nil { data = Data(text.utf8) }
        else if text == nil, let base64, let bytes = Data(base64Encoded: base64) { data = bytes }
        else { throw CocoaError(.fileReadCorruptFile) }
    }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if let text = String(data: data, encoding: .utf8), !text.unicodeScalars.contains(where: { $0.value < 32 && ![9, 10, 13].contains($0.value) }) {
            try values.encode(text, forKey: .text)
        } else { try values.encode(data.base64EncodedString(), forKey: .base64) }
    }
}

struct CaptureStreamArchiveSnapshot: Sendable {
    let owner: CaptureStreamStore
    let directory: URL?
    let summary: CaptureStreamStore.Summary
    let messageLengths: [Int]
    let rawLength: UInt64
    func contents() throws -> RequestLogArchive.ArchiveStream {
        defer { withExtendedLifetime(owner) {} }
        guard let directory else { return .init(summary: summary, messages: [], raw: LogPayload(Data())) }
        let messages = try FileHandle(forReadingFrom: directory.appendingPathComponent("messages"))
        let raw = try FileHandle(forReadingFrom: directory.appendingPathComponent("raw"))
        defer { try? messages.close(); try? raw.close() }
        var result: [RequestLogArchive.ArchiveMessage] = []
        for length in messageLengths {
            try Task.checkCancellation()
            guard let bytes = try messages.read(upToCount: length), bytes.count == length else { throw CocoaError(.fileReadCorruptFile) }
            result.append(.init(try JSONDecoder().decode(CaptureStreamMessage.self, from: bytes)))
        }
        guard rawLength <= UInt64(Int.max) else { throw CocoaError(.fileReadCorruptFile) }
        let rawBytes = rawLength == 0 ? Data() : try raw.read(upToCount: Int(rawLength)) ?? Data()
        guard rawBytes.count == rawLength else { throw CocoaError(.fileReadCorruptFile) }
        return .init(summary: summary, messages: result, raw: LogPayload(rawBytes))
    }
}
