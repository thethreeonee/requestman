import Foundation

struct ScriptInput: Codable, Sendable {
    let source: String
    let request: ScriptMessage
    let response: ScriptMessage?
    let env: [String: String]
    let environmentTypes: [String: EnvironmentValueType]
}

struct ScriptOutput: Codable, Sendable {
    let message: ScriptMessage?
    let error: String?
}

/// Every logical message is fragmented before writing. Pipe reads are never message boundaries.
struct ScriptIPCMessage: Codable, Sendable {
    let kind: String
    var id: UUID?
    var data: Data?
    var error: String?
}

private struct ScriptIPCFragment: Codable {
    let version: Int
    let id: UUID
    let final: Bool
    let bytes: Data
}

enum ScriptIPC {
    static func write(_ message: ScriptIPCMessage, to handle: FileHandle) throws {
        let encoded = try JSONEncoder().encode(message), id = UUID()
        for offset in stride(from: 0, to: encoded.count, by: 16_384) {
            let end = min(encoded.count, offset + 16_384)
            let data = try JSONEncoder().encode(ScriptIPCFragment(version: 1, id: id,
                final: end == encoded.count, bytes: encoded.subdata(in: offset..<end)))
            var length = UInt32(data.count).bigEndian
            try withUnsafeBytes(of: &length) { try handle.write(contentsOf: Data($0)) }
            try handle.write(contentsOf: data)
        }
    }

    static func read(from handle: FileHandle) throws -> ScriptIPCMessage? {
        var payload = Data(), transmission: UUID?
        while true {
            guard let header = try readExactly(4, from: handle) else {
                if transmission != nil { throw WorkflowError.invalid("脚本通信消息不完整") }
                return nil
            }
            let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            // A fragment contains at most 16 KiB of payload, independent of the complete body size.
            guard length > 0, length <= 32_768,
                  let data = try readExactly(Int(length), from: handle) else {
                throw WorkflowError.invalid("脚本通信帧无效")
            }
            let fragment = try JSONDecoder().decode(ScriptIPCFragment.self, from: data)
            guard fragment.version == 1, transmission == nil || transmission == fragment.id else {
                throw WorkflowError.invalid("脚本通信版本或消息身份无效")
            }
            transmission = fragment.id; payload.append(fragment.bytes)
            if fragment.final { return try JSONDecoder().decode(ScriptIPCMessage.self, from: payload) }
        }
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data? {
        var data = Data()
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else {
                if data.isEmpty { return nil }
                throw WorkflowError.invalid("脚本通信帧已截断")
            }
            data.append(chunk)
        }
        return data
    }
}

struct ScriptHTTPMetadata: Codable {
    let status: Int
    let statusText: String
    let headers: [HTTPField]
    let url: String
    let redirected: Bool
}
