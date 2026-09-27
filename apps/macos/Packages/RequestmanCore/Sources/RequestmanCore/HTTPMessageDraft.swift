import Foundation

public struct HTTPField: Equatable, Sendable, Codable {
    public var name: String
    public var value: String
    public init(_ name: String, _ value: String) { self.name = name; self.value = value }
}

public struct HTTPMessageDraft: Sendable, Codable {
    public var method: String
    public var url: String
    public var status: Int
    public var headers: [HTTPField]
    /// nil means stream the original body, including binary data, without inspection.
    public var replacementBody: String?
    public var replacementBodyData: Data?
    public var hasReplacementBody: Bool { replacementBodyData != nil || replacementBody != nil }
    public var replacementBytes: Data? { replacementBodyData ?? replacementBody.map { Data($0.utf8) } }
    public var bodyText: String?
    public var bodyData: Data?
    public var isMock = false
    public init(method: String, url: String, status: Int = 200, headers: [HTTPField] = []) {
        self.method = method; self.url = url; self.status = status; self.headers = headers
    }
    public mutating func setHeader(_ name: String, _ value: String?) {
        headers.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        if let value { headers.append(HTTPField(name, value)) }
    }
}
