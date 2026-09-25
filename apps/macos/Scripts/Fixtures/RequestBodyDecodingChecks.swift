import Foundation
import RequestmanCore

func runBodyDecodingChecks() throws {
    let plain = Data(#"{"message":"hello","count":42,"enabled":true}"#.utf8)
    // Fixed gzip/zlib fixtures generated independently with Python's standard
    // gzip.compress(..., mtime=0) and zlib.compress, without using this decoder.
    let gzip = fixture("H4sIAAAAAAAC/6tWyk0tLk5MT1WyUspIzcnJV9JRSs4vzStRsjIx0lFKzUtMyklNUbIqKSpNrQUAQwlW6C0AAAA=")
    let deflate = fixture("eJyrVspNLS5OTE9VslLKSM3JyVfSUUrOL80rUbIyMdJRSs1LTMpJTVGyKikqTa0FAFj9DyI=")
    let multiple = fixture("eJyT7+ZgAAGm/6vDTvnq6vn5+IduCjrlcfbkyfBLgV7n9M9qB24yMgQyz3r7nPL0Ddykpanlu5aVwZkz7IUuUCMAD9kXYA==")
    let empty = fixture("H4sIAAAAAAAC/wMAAAAAAAAAAAA=")
    let atLimit = fixture("H4sIAAAAAAAC/+3BMQEAAADCoKzrX8LbDkABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAALwBxI2NugAABAA=")
    let overLimit = fixture("H4sIAAAAAAAC/+3BMQEAAADCoKzrX8LfDEABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAJwBZzUEdAEABAA=")
    var corruptChecksum = gzip
    corruptChecksum[corruptChecksum.count - 8] ^= 0xff
    let largeInput = Data((0..<(512 * 1_024 + 3)).map { UInt8(truncatingIfNeeded: $0) })

    let cases: [BodyDecodingCheck] = [
        .init("identity", bytes: plain, expected: plain),
        .init("explicit identity", bytes: plain, encoding: "identity", expected: plain),
        .init("compressed input across read chunks", bytes: storedZlib(largeInput), encoding: "deflate", expected: largeInput),
        .init("gzip", bytes: gzip, encoding: "gzip", expected: plain),
        .init("deflate", bytes: deflate, encoding: "deflate", expected: plain),
        .init("multiple encodings", bytes: multiple, encoding: "gzip, deflate", expected: plain),
        .init("empty gzip", bytes: empty, encoding: "gzip", expected: Data()),
        .init("exact output limit", bytes: atLimit, encoding: "gzip",
              expected: Data(repeating: 0x61, count: (256 * 1_024))),
        .init("output beyond former limit", bytes: overLimit, encoding: "gzip", expected: Data(repeating: 0x61, count: 256 * 1_024 + 1)),
        .init("truncated gzip", bytes: Data(gzip.dropLast()), encoding: "gzip", error: .truncatedCompressedData),
        .init("corrupt checksum", bytes: corruptChecksum, encoding: "gzip", error: .invalidCompressedData),
        .init("trailing bytes", bytes: gzip + Data("trailing".utf8), encoding: "gzip", error: .trailingCompressedData),
        .init("concatenated gzip", bytes: gzip + gzip, encoding: "gzip", error: .concatenatedGzipMembers),
        .init("raw deflate", bytes: Data(deflate.dropFirst(2).dropLast(4)), encoding: "deflate", error: .invalidCompressedData),
        .init("empty compressed input", bytes: Data(), encoding: "gzip", error: .truncatedCompressedData),
        .init("unsupported br", bytes: plain, encoding: "br", error: .unsupportedEncoding("br")),
        .init("incomplete record", bytes: gzip, encoding: "gzip", error: .incompleteSnapshot, isComplete: false),
        .init("invalid encoding list", bytes: gzip, encoding: "gzip,,identity", error: .invalidEncoding),
        .init("excessive encoding layers", bytes: plain,
              encoding: Array(repeating: "identity", count: 9).joined(separator: ","), expected: plain),
        .init("case insensitive encoding", bytes: gzip, encoding: " GZip ", expected: plain),
    ]
    for test in cases {
        let headers = test.encoding.map { [HTTPField("Content-Encoding", $0)] } ?? []
        let collector = CaptureBodyCollector(headers: headers)
        collector.append(test.bytes)
        let snapshot = collector.snapshot(isComplete: test.isComplete)
        do {
            let result = try RequestBodyDecoding.decode(snapshot)
            precondition(test.error == nil, "\(test.name): expected \(String(describing: test.error))")
            precondition(result == test.expected, "\(test.name): unexpected decoded bytes")
        } catch {
            guard let expected = test.error else { throw error }
            precondition(error as? RequestBodyDecoding.DecodingError == expected, "\(test.name): unexpected error \(error)")
            precondition((error as? LocalizedError)?.errorDescription?.isEmpty == false,
                         "\(test.name): decoding errors must explain the unavailable preview")
        }
    }
    print("Body decoding checks passed: \(cases.count) fixtures, actual capture snapshots, gzip/deflate, large output and malformed input")
}

private struct BodyDecodingCheck {
    let name: String
    let bytes: Data
    let encoding: String?
    let expected: Data?
    let error: RequestBodyDecoding.DecodingError?
    let isComplete: Bool

    init(_ name: String, bytes: Data, encoding: String? = nil, expected: Data? = nil,
         error: RequestBodyDecoding.DecodingError? = nil, isComplete: Bool = true) {
        self.name = name
        self.bytes = bytes
        self.encoding = encoding
        self.expected = expected
        self.error = error
        self.isComplete = isComplete
    }
}

private func fixture(_ base64: String) -> Data {
    guard let data = Data(base64Encoded: base64) else { preconditionFailure("Invalid compressed fixture") }
    return data
}

// Independent uncompressed DEFLATE blocks exercise incremental zlib input beyond 64 KiB.
private func storedZlib(_ data: Data) -> Data {
    var result = Data([0x78, 0x01])
    var offset = 0
    while offset < data.count {
        let count = min(65_535, data.count - offset)
        let length = UInt16(count)
        result.append(offset + count == data.count ? 1 : 0)
        for value in [length, ~length] {
            result.append(UInt8(truncatingIfNeeded: value))
            result.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        result.append(data[offset..<(offset + count)])
        offset += count
    }
    var a: UInt32 = 1, b: UInt32 = 0
    for byte in data { a = (a + UInt32(byte)) % 65_521; b = (b + a) % 65_521 }
    let checksum = (b << 16) | a
    for shift in [24, 16, 8, 0] { result.append(UInt8(truncatingIfNeeded: checksum >> shift)) }
    return result
}
