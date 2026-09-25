import Foundation
import RequestmanCore

func runCURLChecks() throws {
    try checkCURLVersionsAndQuoting()
    try checkCURLBinaryAndHeaders()
    try checkCURLEmptyAndUnavailable()
    print("cURL checks passed: original/final selection, sh/zsh quoting, literal @, binary/compressed stdin, headers and completeness")
}

private func checkCURLVersionsAndQuoting() throws {
    let url = ("https://example.test/a/../[1]/{x,y}?quote='&arg=$(printf injection)&雪=1&long=" + String(repeating: "x", count: 8_192))
        .replacingOccurrences(of: " ", with: "%20")
    let text = "@payload.json\n{\"quote\":\"'`printf injection`$(printf injection)\\\\雪\"}\r\n"
    var record = CaptureRecord(method: "POST", url: url)
    record.requestHeaders = [HTTPField("Host", "virtual.example.test"), HTTPField("X-Quote", "'$(printf injection)`printf injection`"), HTTPField("X-Empty", ""), HTTPField("X-Empty", "")]
    record.requestBody = bodySnapshot(Data(text.utf8))
    record.sentMethod = "PATCH"
    record.finalURL = "https://final.example.test/changed"
    record.sentHeaders = [HTTPField("Content-Type", "application/json")]
    record.sentBody = bodySnapshot(Data(#"{"final":true}"#.utf8))
    let cookie = "session=" + String(repeating: "a", count: 8_192)
    record.requestHeaders.append(HTTPField("Cookie", cookie + "; source=original"))
    record.sentHeaders.append(HTTPField("Cookie", cookie + "; source=modified"))
    record = record.bounded()
    for shell in ["/bin/sh", "/bin/zsh"] {
        let before = try captureCURL(requireCommand(record, .original), shell: shell)
        precondition(option("--request", in: before.arguments) == "POST")
        precondition(option("--url", in: before.arguments) == url, "Shell expansion must not change the URL")
        precondition(option("--data-raw", in: before.arguments) == text, "Text including leading @, CRLF, quotes and substitutions must remain literal")
        precondition(before.input.isEmpty)
        precondition(before.arguments.first == "--disable" && before.arguments.contains("--globoff") && before.arguments.contains("--path-as-is"))
        precondition(headerValues(before.arguments).contains("Host: virtual.example.test"))
        precondition(headerValues(before.arguments).contains("Cookie: " + cookie + "; source=original"))
        precondition(headerValues(before.arguments).contains("X-Quote: '$(printf injection)`printf injection`"))
        precondition(headerValues(before.arguments).filter { $0 == "X-Empty;" }.count == 2, "Duplicate empty headers remain separate, present fields")
        precondition(headerValues(before.arguments).contains("Content-Type:"), "curl's form content type must not be invented")
        let after = try captureCURL(requireCommand(record, .modified), shell: shell)
        precondition(option("--request", in: after.arguments) == "PATCH")
        precondition(option("--url", in: after.arguments) == record.finalURL)
        precondition(option("--data-raw", in: after.arguments) == #"{"final":true}"#)
        precondition(headerValues(after.arguments).contains("Content-Type: application/json"))
        precondition(headerValues(after.arguments).contains("Cookie: " + cookie + "; source=modified"))
        precondition(!headerValues(after.arguments).contains("Content-Type:"))
    }
}

private func checkCURLBinaryAndHeaders() throws {
    let binary = Data([0, 1, 2, 255, 13, 10, 64, 39]) + Data((0..<256).map(UInt8.init))
    var record = CaptureRecord(method: "PUT", url: "https://example.test/binary")
    record.requestHeaders = [HTTPField("Content-Length", "9999"), HTTPField("Transfer-Encoding", "chunked"),
                             HTTPField("Connection", "close, X-Hop"), HTTPField("X-Hop", "connection-only"),
                             HTTPField("X-Value", "one"), HTTPField("X-Value", "two"), HTTPField("Content-Encoding", "gzip"),
                             HTTPField("Authorization", "secret"), HTTPField("Cookie", "session=abc; theme=dark")]
    record.requestBody = bodySnapshot(binary, headers: record.requestHeaders)
    record = record.bounded()
    let command = requireCommand(record, .original)
    precondition(command.hasPrefix("printf ") && !command.contains("已脱敏"))
    for shell in ["/bin/sh", "/bin/zsh"] {
        let result = try captureCURL(command, shell: shell)
        precondition(result.input == binary, "Binary and content-encoded entity bytes must be replayed without decoding or normalization")
        precondition(option("--data-binary", in: result.arguments) == "@-")
        precondition(option("--data-raw", in: result.arguments) == nil)
        let headers = headerValues(result.arguments)
        precondition(!headers.contains { $0.lowercased().hasPrefix("content-length:") || $0.lowercased().hasPrefix("transfer-encoding:") || $0.lowercased().hasPrefix("x-hop:") })
        precondition(headers.filter { $0.hasPrefix("X-Value:") } == ["X-Value: one", "X-Value: two"])
        precondition(headers.contains("Content-Encoding: gzip") && headers.contains("Authorization: secret"))
        precondition(headers.contains("Cookie: session=abc; theme=dark"))
        precondition(["Accept:", "User-Agent:", "Expect:", "Content-Type:"].allSatisfy(headers.contains))
    }
    let interactive = try captureCURL(command, shell: "/bin/zsh", interactive: true)
    precondition(interactive.input == binary, "Binary exports must work in interactive zsh")
    precondition(headerValues(interactive.arguments).contains("Authorization: secret"))
    // Even text-shaped content-encoded bytes must use the binary route, never an implicit decompression.
    record.requestBody = bodySnapshot(Data("encoded-ascii".utf8), headers: [HTTPField("Content-Encoding", "deflate")])
    let encoded = try captureCURL(requireCommand(record, .original), shell: "/bin/sh")
    precondition(encoded.input == Data("encoded-ascii".utf8) && option("--data-binary", in: encoded.arguments) == "@-")
}

private func checkCURLEmptyAndUnavailable() throws {
    var record = CaptureRecord(method: "GET", url: "https://example.test/empty")
    record.requestBody = bodySnapshot(Data())
    let empty = try captureCURL(requireCommand(record, .original), shell: "/bin/sh")
    precondition(option("--data-binary", in: empty.arguments) == nil && empty.input.isEmpty)
    record.requestHeaders = [HTTPField("Content-Length", "0")]
    let explicitEmpty = try captureCURL(requireCommand(record, .original), shell: "/bin/sh")
    precondition(option("--data-binary", in: explicitEmpty.arguments) == "")
    record.method = "HEAD"
    let head = try captureCURL(requireCommand(record, .original), shell: "/bin/sh")
    precondition(head.arguments.contains("--head") && option("--data-binary", in: head.arguments) == nil)
    precondition(headerValues(head.arguments).contains("Content-Length: 0"))
    record.requestBody = bodySnapshot(Data("unexpected-body".utf8))
    assertUnavailable(record)
    record.method = "head"
    let customMethod = try captureCURL(requireCommand(record, .original), shell: "/bin/sh")
    precondition(!customMethod.arguments.contains("--head"), "HTTP method names remain case-sensitive")
    precondition(option("--request", in: customMethod.arguments) == "head")
    record.method = "GET"
    record.requestBody = bodySnapshot(Data())
    record.urlWasTruncated = true
    assertUnavailable(record)
    record.urlWasTruncated = false
    record.requestHeadersInfo.isTruncated = true
    assertUnavailable(record)
    record.requestHeadersInfo = .init()
    record.requestHeadersInfo.truncatedNames = ["x-header"]
    assertUnavailable(record)
    record.requestHeadersInfo = .init()
    record.requestHeadersInfo.originalCount = 2
    assertUnavailable(record)
    record.requestHeadersInfo = .init()
    for field in [HTTPField("@file", "value"), HTTPField("X-Test", "a\r\nb"), HTTPField("X-Test", "a\0b"), HTTPField("X-\nCommand", "value")] {
        record.requestHeaders = [field]
        assertUnavailable(record)
    }
    record.requestHeaders = []
    for body in [CaptureBodySnapshot.notCollected, .unavailable("没有上游请求"), bodySnapshot(Data(), complete: false)] {
        record.requestBody = body
        assertUnavailable(record)
    }
    record.requestBody = bodySnapshot(Data())
    record.finalURLWasTruncated = true
    record.sentBody = bodySnapshot(Data())
    precondition(RequestCURL.command(for: record, version: .modified) == nil)
    precondition(RequestCURL.command(for: record, version: .original) != nil, "Availability is independent for original and modified snapshots")
}

private func bodySnapshot(_ data: Data, headers: [HTTPField] = [], complete: Bool = true) -> CaptureBodySnapshot {
    let collector = CaptureBodyCollector(headers: headers)
    collector.append(data)
    return collector.snapshot(isComplete: complete)
}

private func requireCommand(_ record: CaptureRecord, _ version: RequestCURL.Version) -> String {
    guard let command = RequestCURL.command(for: record, version: version) else {
        preconditionFailure(RequestCURL.unavailableReason(for: record, version: version) ?? "Expected command")
    }
    return command
}

private func assertUnavailable(_ record: CaptureRecord) {
    precondition(RequestCURL.unavailableReason(for: record, version: .original) != nil)
    precondition(RequestCURL.command(for: record, version: .original) == nil, "Incomplete or ambiguous requests cannot be exported")
}

private func option(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

private func headerValues(_ arguments: [String]) -> [String] {
    arguments.enumerated().compactMap { index, value in value == "--header" ? arguments[index + 1] : nil }
}

private struct CURLCapture { let arguments: [String]; let input: Data }

private func captureCURL(_ command: String, shell: String, interactive: Bool = false) throws -> CURLCapture {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    // The function shadows curl completely: arguments go to stdout; entity bytes go to stderr.
    // No curl executable, sockets, files from payloads or external servers are accessed.
    let script = "curl() { printf '%s\\000' \"$@\"; /bin/cat >&2; }\n" + command
    if interactive {
        // -f skips user startup files; require the default comment behavior before running the stub.
        process.arguments = ["-f", "-i", "-c", "[[ $options[interactivecomments] == off ]] || exit 97\n" + script]
    } else { process.arguments = ["-c", script] }
    process.standardInput = FileHandle.nullDevice
    let output = Pipe(), input = Pipe()
    process.standardOutput = output
    process.standardError = input
    try process.run()
    let argumentBytes = output.fileHandleForReading.readDataToEndOfFile()
    let body = input.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    precondition(process.terminationStatus == 0, "Shell stub failed: " + String(decoding: body, as: UTF8.self))
    var pieces = argumentBytes.split(separator: 0, omittingEmptySubsequences: false)
    precondition(pieces.last?.isEmpty == true)
    pieces.removeLast()
    return CURLCapture(arguments: pieces.map { String(decoding: $0, as: UTF8.self) }, input: body)
}
