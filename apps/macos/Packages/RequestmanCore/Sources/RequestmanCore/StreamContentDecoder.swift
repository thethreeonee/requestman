import Foundation
import zlib

/// Queue-confined incremental HTTP content decoder for observing SSE without altering wire bytes.
final class StreamContentDecoder {
    private let layers: [Inflater]
    init(encoding: String?) throws {
        let names = (encoding ?? "identity").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        layers = try names.reversed().compactMap { name in
            if name == "identity" { return nil }
            guard ["gzip", "x-gzip", "deflate"].contains(name) else {
                throw WorkflowError.invalid("事件流暂不支持 \(name) 内容编码；网络仍原样转发")
            }
            return try Inflater(gzip: name != "deflate")
        }
    }
    func append(_ data: Data) throws -> Data {
        try layers.reduce(data) { try $1.append($0) }
    }
    private final class Inflater {
        private var stream = z_stream()
        private var ended = false
        private let bits: Int32
        init(gzip: Bool) throws {
            bits = Int32(MAX_WBITS) + (gzip ? 16 : 0)
            guard inflateInit2_(&stream, bits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw WorkflowError.invalid("无法初始化事件流解压器")
            }
        }
        deinit { inflateEnd(&stream) }
        func append(_ data: Data) throws -> Data {
            guard !data.isEmpty else { return Data() }
            var result = Data()
            try data.withUnsafeBytes { input in
                guard let base = input.bindMemory(to: Bytef.self).baseAddress else { return }
                var consumed = 0
                while consumed < data.count {
                    if ended {
                        guard inflateReset2(&stream, bits) == Z_OK else { throw WorkflowError.invalid("事件流解压重置失败") }
                        ended = false
                    }
                    let count = min(data.count - consumed, Int(UInt32.max))
                    stream.next_in = UnsafeMutablePointer(mutating: base.advanced(by: consumed)); stream.avail_in = UInt32(count)
                    repeat {
                        var output = [UInt8](repeating: 0, count: 16_384)
                        let status: Int32 = output.withUnsafeMutableBytes { destination in
                            stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress; stream.avail_out = UInt32(destination.count)
                            return inflate(&stream, Z_NO_FLUSH)
                        }
                        let produced = output.count - Int(stream.avail_out)
                        result.append(contentsOf: output.prefix(produced))
                        if status == Z_STREAM_END { ended = true; break }
                        guard status == Z_OK || status == Z_BUF_ERROR else { throw WorkflowError.invalid("事件流压缩内容损坏") }
                        if stream.avail_in == 0 && produced < output.count { break }
                        if status == Z_BUF_ERROR && produced == 0 { break }
                    } while true
                    let used = count - Int(stream.avail_in)
                    consumed += used
                    if used == 0 && !ended { break }
                }
            }
            stream.next_in = nil; stream.next_out = nil
            return result
        }
    }
}
