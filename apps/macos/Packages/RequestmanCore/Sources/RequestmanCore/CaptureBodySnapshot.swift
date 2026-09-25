import Foundation
import os

/// A bounded prefix of the HTTP entity bytes, after transfer framing and before content decoding.
/// Keep the snapshot alive while using its data; independent copies/decoded trees need their own UI budget.
public struct CaptureBodySnapshot: Sendable {
    public enum State: String, Sendable { case notCollected, complete, incomplete, unavailable }
    public static let maximumBytes = 65_536
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

/// Shared across live collectors, queued records and retained history. Exhaustion truncates previews only.
public final class CaptureBodyBudget: Sendable {
    public static let shared = CaptureBodyBudget()
    public let capacity: Int
    private let used = OSAllocatedUnfairLock(initialState: 0)
    public var usedByteCount: Int { used.withLock { $0 } }
    public init(capacity: Int = 32 * 1_048_576) { self.capacity = max(0, capacity) }
    fileprivate func reserve(upTo requested: Int) -> Int {
        used.withLock { count in
            let reserved = min(max(0, requested), capacity - count)
            count += reserved
            return reserved
        }
    }
    fileprivate func release(_ count: Int) { used.withLock { $0 -= count } }
}

private final class CaptureBodyLease: Sendable {
    let budget: CaptureBodyBudget
    private let count = OSAllocatedUnfairLock(initialState: 0)
    init(budget: CaptureBodyBudget) { self.budget = budget }
    func reserve(upTo bytes: Int) -> Int {
        let reserved = budget.reserve(upTo: bytes)
        count.withLock { $0 += reserved }
        return reserved
    }
    deinit { budget.release(count.withLock { $0 }) }
}

private final class CaptureBodyStorage: Sendable {
    let data: Data
    let lease: CaptureBodyLease
    init(data: Data, lease: CaptureBodyLease) { self.data = data; self.lease = lease }
}

/// Mutable, event-loop confined collector. Appending never waits for or buffers the complete body.
public final class CaptureBodyCollector {
    private var data = Data()
    private var observedByteCount = 0
    private var truncated = false
    private var frozenSnapshot: CaptureBodySnapshot?
    private let lease: CaptureBodyLease
    private let maximumBytes: Int
    private let contentType: String?
    private let contentEncoding: String?
    public init(headers: [HTTPField] = [], budget: CaptureBodyBudget = .shared,
                maximumBytes: Int = CaptureBodySnapshot.maximumBytes) {
        lease = CaptureBodyLease(budget: budget)
        self.maximumBytes = min(CaptureBodySnapshot.maximumBytes, max(0, maximumBytes))
        contentType = headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
        let encodings = headers.filter { $0.name.caseInsensitiveCompare("Content-Encoding") == .orderedSame }.map(\.value)
        contentEncoding = encodings.isEmpty ? nil : encodings.joined(separator: ", ")
    }
    public func append<Bytes: Collection>(_ bytes: Bytes) where Bytes.Element == UInt8 {
        guard frozenSnapshot == nil else { return }
        observedByteCount += bytes.count
        // Once a gap exists, never append later bytes: retained data must remain an actual prefix.
        guard !truncated else { return }
        let retained = lease.reserve(upTo: min(maximumBytes - data.count, bytes.count))
        data.append(contentsOf: bytes.prefix(retained))
        if retained < bytes.count { truncated = true }
    }
    public func snapshot(isComplete: Bool) -> CaptureBodySnapshot {
        if let frozenSnapshot { return frozenSnapshot }
        let snapshot = CaptureBodySnapshot(state: isComplete ? .complete : .incomplete, observedByteCount: observedByteCount,
                                           isTruncated: truncated, contentType: contentType, contentEncoding: contentEncoding,
                                           storage: CaptureBodyStorage(data: data, lease: lease))
        frozenSnapshot = snapshot
        return snapshot
    }
}
