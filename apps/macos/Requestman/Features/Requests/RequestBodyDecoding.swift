import Foundation
import RequestmanCore
import zlib

/// Decodes a complete capture only when its detail view is opened.
/// Call from the inspection worker, never while forwarding network traffic.
enum RequestBodyDecoding {

    enum DecodingError: LocalizedError, Sendable, Equatable {
        case incompleteSnapshot
        case unsupportedEncoding(String)
        case invalidEncoding
        case invalidCompressedData
        case truncatedCompressedData
        case trailingCompressedData
        case concatenatedGzipMembers
        case decoderUnavailable

        var errorDescription: String? {
            switch self {
            case .incompleteSnapshot:
                "内容未完整采集，无法解压。"
            case .unsupportedEncoding(let encoding):
                "暂不支持 \(encoding) 内容编码。"
            case .invalidEncoding:
                "内容编码格式无效，无法解压。"
            case .invalidCompressedData:
                "压缩内容已损坏或格式不受支持，无法解压。"
            case .truncatedCompressedData:
                "压缩内容不完整，无法解压。"
            case .trailingCompressedData:
                "压缩内容末尾存在额外数据，无法预览。"
            case .concatenatedGzipMembers:
                "暂不支持包含多个拼接成员的 gzip 内容。"
            case .decoderUnavailable:
                "无法初始化内容解压器。"
            }
        }
    }

    static func decode(_ snapshot: CaptureBodySnapshot) throws -> Data {
        guard snapshot.isComplete else { throw DecodingError.incompleteSnapshot }
        try Task.checkCancellation()
        guard let encodingHeader = snapshot.contentEncoding,
              !encodingHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return snapshot.data
        }

        let encodings = encodingHeader.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard !encodings.contains("") else { throw DecodingError.invalidEncoding }
        for encoding in encodings where !["identity", "gzip", "x-gzip", "deflate"].contains(encoding) {
            throw DecodingError.unsupportedEncoding(encoding)
        }

        var data = snapshot.data
        // Content-Encoding lists the encodings in application order. Undo the
        // outermost layer first.
        for encoding in encodings.reversed() {
            try Task.checkCancellation()
            switch encoding {
            case "identity": break
            case "gzip", "x-gzip": data = try inflate(data, gzip: true)
            case "deflate": data = try inflate(data, gzip: false)
            default: throw DecodingError.unsupportedEncoding(encoding)
            }
        }
        return data
    }

    private static func inflate(_ data: Data, gzip: Bool) throws -> Data {
        var stream = z_stream()
        // HTTP "deflate" is a zlib-wrapped stream. Do not guess raw DEFLATE
        // after a checksum or format error, which could accept damaged input.
        let windowBits = Int32(MAX_WBITS) + (gzip ? 16 : 0)
        guard inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw DecodingError.decoderUnavailable
        }
        defer { inflateEnd(&stream) }

        return try data.withUnsafeBytes { input in
            let bytes = input.bindMemory(to: Bytef.self)
            var inputOffset = 0
            var output = Data()
            output.reserveCapacity(max(1_024, data.count))
            var buffer = [UInt8](repeating: 0, count: 16 * 1_024)

            while true {
                try Task.checkCancellation()
                // zlib uses a 32-bit input count; feed chunks so large captures never narrow an Int.
                if stream.avail_in == 0, inputOffset < bytes.count {
                    let count = min(64 * 1_024, bytes.count - inputOffset)
                    stream.next_in = UnsafeMutablePointer(mutating: bytes.baseAddress!.advanced(by: inputOffset))
                    stream.avail_in = uInt(count)
                    inputOffset += count
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
                    let offset = inputOffset - Int(stream.avail_in)
                    guard offset == bytes.count else {
                        if gzip, bytes.count - offset >= 2, bytes[offset] == 0x1f, bytes[offset + 1] == 0x8b {
                            throw DecodingError.concatenatedGzipMembers
                        }
                        throw DecodingError.trailingCompressedData
                    }
                    return output
                }

                switch status {
                case Z_OK:
                    if produced == 0, stream.avail_in == 0, inputOffset == bytes.count {
                        throw DecodingError.truncatedCompressedData
                    }
                    guard produced > 0 || stream.avail_in < previousInput else {
                        throw DecodingError.invalidCompressedData
                    }
                case Z_BUF_ERROR:
                    if stream.avail_in == 0 { throw DecodingError.truncatedCompressedData }
                    throw DecodingError.invalidCompressedData
                default:
                    throw DecodingError.invalidCompressedData
                }
            }
        }
    }
}
