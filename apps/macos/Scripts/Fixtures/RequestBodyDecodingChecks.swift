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

    let cases: [BodyDecodingCheck] = [
        .init("identity", bytes: plain, expected: plain),
        .init("explicit identity", bytes: plain, encoding: "identity", expected: plain),
        .init("gzip", bytes: gzip, encoding: "gzip", expected: plain),
        .init("deflate", bytes: deflate, encoding: "deflate", expected: plain),
        .init("multiple encodings", bytes: multiple, encoding: "gzip, deflate", expected: plain),
        .init("empty gzip", bytes: empty, encoding: "gzip", expected: Data()),
        .init("exact output limit", bytes: atLimit, encoding: "gzip",
              expected: Data(repeating: 0x61, count: RequestBodyDecoding.maximumDecodedBytes)),
        .init("oversized output", bytes: overLimit, encoding: "gzip", error: .decodedBodyTooLarge),
        .init("truncated gzip", bytes: Data(gzip.dropLast()), encoding: "gzip", error: .truncatedCompressedData),
        .init("corrupt checksum", bytes: corruptChecksum, encoding: "gzip", error: .invalidCompressedData),
        .init("trailing bytes", bytes: gzip + Data("trailing".utf8), encoding: "gzip", error: .trailingCompressedData),
        .init("concatenated gzip", bytes: gzip + gzip, encoding: "gzip", error: .concatenatedGzipMembers),
        .init("raw deflate", bytes: Data(deflate.dropFirst(2).dropLast(4)), encoding: "deflate", error: .invalidCompressedData),
        .init("empty compressed input", bytes: Data(), encoding: "gzip", error: .truncatedCompressedData),
        .init("unsupported br", bytes: plain, encoding: "br", error: .unsupportedEncoding("br")),
        .init("incomplete record", bytes: gzip, encoding: "gzip", error: .incompleteSnapshot, isComplete: false),
        .init("truncated snapshot", bytes: gzip, encoding: "gzip", error: .incompleteSnapshot, maximumBytes: 5),
        .init("invalid encoding list", bytes: gzip, encoding: "gzip,,identity", error: .invalidEncoding),
        .init("excessive encoding layers", bytes: plain,
              encoding: Array(repeating: "identity", count: 9).joined(separator: ","), error: .tooManyEncodings),
        .init("case insensitive encoding", bytes: gzip, encoding: " GZip ", expected: plain),
    ]
    precondition(RequestBodyDecoding.maximumDecodedBytes == 256 * 1_024)
    for test in cases {
        let headers = test.encoding.map { [HTTPField("Content-Encoding", $0)] } ?? []
        let collector = CaptureBodyCollector(headers: headers, budget: CaptureBodyBudget(), maximumBytes: test.maximumBytes)
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
    print("Body decoding checks passed: \(cases.count) fixtures, actual capture snapshots, gzip/deflate and resource bounds")
}

private struct BodyDecodingCheck {
    let name: String
    let bytes: Data
    let encoding: String?
    let expected: Data?
    let error: RequestBodyDecoding.DecodingError?
    let isComplete: Bool
    let maximumBytes: Int

    init(_ name: String, bytes: Data, encoding: String? = nil, expected: Data? = nil,
         error: RequestBodyDecoding.DecodingError? = nil, isComplete: Bool = true,
         maximumBytes: Int = CaptureBodySnapshot.maximumBytes) {
        self.name = name
        self.bytes = bytes
        self.encoding = encoding
        self.expected = expected
        self.error = error
        self.isComplete = isComplete
        self.maximumBytes = maximumBytes
    }
}

private func fixture(_ base64: String) -> Data {
    guard let data = Data(base64Encoded: base64) else { preconditionFailure("Invalid compressed fixture") }
    return data
}
