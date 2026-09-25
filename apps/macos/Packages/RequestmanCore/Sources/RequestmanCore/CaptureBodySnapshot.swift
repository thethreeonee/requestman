import Foundation

/// HTTP entity bytes after transfer framing and before content decoding.
public struct CaptureBodySnapshot: Sendable {
    public enum State: String, Sendable { case notCollected, complete, incomplete, unavailable }
    public let state: State
    public let observedByteCount: Int
    public let isTruncated: Bool
    public let contentType: String?
    public let contentEncoding: String?
    public let unavailableReason: String?
    private let storage: CaptureBodyStorage?
    public var data: Data { storage?.data ?? Data() }
    public var isEncoded: Bool {
        guard let contentEncoding else { return false }
        return contentEncoding.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces).lowercased() != "identity" }
    }
    public var isComplete: Bool { state == .complete && !isTruncated }
    public static let notCollected = CaptureBodySnapshot(state: .notCollected)
    public static func unavailable(_ reason: String) -> Self { Self(state: .unavailable, unavailableReason: reason) }
    fileprivate init(state: State, observedByteCount: Int = 0, isTruncated: Bool = false,
                     contentType: String? = nil, contentEncoding: String? = nil,
                     unavailableReason: String? = nil, storage: CaptureBodyStorage? = nil) {
        self.state = state; self.observedByteCount = observedByteCount; self.isTruncated = isTruncated
        self.contentType = contentType; self.contentEncoding = contentEncoding
        self.unavailableReason = unavailableReason; self.storage = storage
    }
}

private final class CaptureBodyStorage: Sendable {
    let data: Data
    init(data: Data) { self.data = data }
}

/// Event-loop confined collector. Capture every chunk without delaying forwarding until EOF.
public final class CaptureBodyCollector {
    private var data = Data()
    private var observedByteCount = 0
    private var frozenSnapshot: CaptureBodySnapshot?
    private let contentType: String?
    private let contentEncoding: String?
    public init(headers: [HTTPField] = []) {
        contentType = headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
        let encodings = headers.filter { $0.name.caseInsensitiveCompare("Content-Encoding") == .orderedSame }.map(\.value)
        contentEncoding = encodings.isEmpty ? nil : encodings.joined(separator: ", ")
    }
    public func append<Bytes: Collection>(_ bytes: Bytes) where Bytes.Element == UInt8 {
        guard frozenSnapshot == nil else { return }
        observedByteCount += bytes.count
        data.append(contentsOf: bytes)
    }
    public func snapshot(isComplete: Bool) -> CaptureBodySnapshot {
        if let frozenSnapshot { return frozenSnapshot }
        let snapshot = CaptureBodySnapshot(state: isComplete ? .complete : .incomplete, observedByteCount: observedByteCount,
                                           contentType: contentType, contentEncoding: contentEncoding,
                                           storage: CaptureBodyStorage(data: data))
        frozenSnapshot = snapshot
        return snapshot
    }
}
