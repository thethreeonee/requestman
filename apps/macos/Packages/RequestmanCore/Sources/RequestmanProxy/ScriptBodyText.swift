import Foundation
import RequestmanCore
import zlib

/// Complete bodies only, off the event loop. Never silently replace undecodable bytes.
enum ScriptBodyText {
    static func decode(_ bytes: Data, headers: [HTTPField], control: ScriptExecutionControl) throws -> String? {
        do { return String(data: try decodeData(bytes, headers: headers, control: control), encoding: .utf8) }
        catch is ContentDecodingFailure { return nil }
    }
    static func decodeData(_ bytes: Data, headers: [HTTPField], control: ScriptExecutionControl) throws -> Data {
        try control.check()
        var data = bytes
        let encodings = headers.filter { $0.name.lowercased() == "content-encoding" }.flatMap {
            $0.value.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        }
        for encoding in encodings.reversed() {
            try control.check()
            switch encoding {
            case "identity": break
            case "gzip", "x-gzip", "deflate":
                guard let decoded = try inflate(data, gzip: encoding != "deflate", control: control) else {
                    throw ContentDecodingFailure.damaged
                }
                data = decoded
            default: throw ContentDecodingFailure.unsupported(encoding)
            }
        }
        return data
    }
    private static func inflate(_ data: Data, gzip: Bool, control: ScriptExecutionControl) throws -> Data? {
        var stream = z_stream()
        guard inflateInit2_(&stream, Int32(MAX_WBITS) + (gzip ? 16 : 0), ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { input -> Data? in
            let bytes = input.bindMemory(to: Bytef.self)
            var offset = 0, output = Data()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                try control.check()
                if stream.avail_in == 0, offset < bytes.count {
                    let count = min(65_536, bytes.count - offset)
                    stream.next_in = UnsafeMutablePointer(mutating: bytes.baseAddress!.advanced(by: offset))
                    stream.avail_in = uInt(count); offset += count
                }
                let previousInput = stream.avail_in
                let status = buffer.withUnsafeMutableBytes { destination in
                    stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(destination.count)
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }
                let produced = buffer.count - Int(stream.avail_out)
                output.append(contentsOf: buffer.prefix(produced))
                if status == Z_STREAM_END {
                    let consumed = offset - Int(stream.avail_in)
                    if consumed == bytes.count { return output }
                    guard gzip, inflateReset2(&stream, Int32(MAX_WBITS) + 16) == Z_OK else { return nil }
                    offset = consumed; stream.avail_in = 0; stream.next_in = nil
                    continue
                }
                guard status == Z_OK, produced > 0 || stream.avail_in < previousInput else { return nil }
            }
        }
    }
}

private enum ContentDecodingFailure: LocalizedError {
    case damaged, unsupported(String)
    var errorDescription: String? {
        switch self {
        case .damaged: "响应压缩内容损坏"
        case .unsupported(let encoding): "暂不支持 \(encoding) 内容编码"
        }
    }
}
