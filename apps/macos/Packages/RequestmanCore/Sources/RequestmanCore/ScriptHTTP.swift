import Foundation

/// Serializable input to the host's auxiliary HTTP transport. It never enters rule matching.
public struct ScriptHTTPRequest: Codable, Sendable {
    public enum Redirect: String, Codable, Sendable { case follow, error, manual }
    public var url: String
    public var method: String
    public var headers: [HTTPField]
    public var body: Data?
    public var redirect: Redirect
    public init(url: String, method: String = "GET", headers: [HTTPField] = [], body: Data? = nil,
                redirect: Redirect = .follow) {
        self.url = url; self.method = method; self.headers = headers; self.body = body; self.redirect = redirect
    }
}

/// Host-assigned identity; routing and parent identity cannot be chosen by JavaScript.
public struct ScriptHTTPContext: Sendable {
    public let executionID: UUID
    public let callID: UUID
    public let parentTransactionID: UUID?
    public let stepID: UUID?
    public init(executionID: UUID, callID: UUID, parentTransactionID: UUID? = nil, stepID: UUID? = nil) {
        self.executionID = executionID; self.callID = callID
        self.parentTransactionID = parentTransactionID; self.stepID = stepID
    }
}

/// Headers are available before the body completes. readBody returns decoded fetch bytes;
/// the transport retains original encoded bytes for capture. Unread responses are cancelled on script exit.
public struct ScriptHTTPResponse: Sendable {
    public let status: Int
    public let statusText: String
    public let headers: [HTTPField]
    public let url: String
    public let redirected: Bool
    public let readBody: @Sendable () async throws -> Data
    public let cancel: @Sendable () -> Void
    public init(status: Int, statusText: String = "", headers: [HTTPField] = [], url: String,
                redirected: Bool = false, readBody: @escaping @Sendable () async throws -> Data,
                cancel: @escaping @Sendable () -> Void = {}) {
        self.status = status; self.statusText = statusText; self.headers = headers
        self.url = url; self.redirected = redirected; self.readBody = readBody; self.cancel = cancel
    }
}

public protocol ScriptHTTPClient: Sendable {
    func send(_ request: ScriptHTTPRequest, context: ScriptHTTPContext,
              control: ScriptExecutionControl) async throws -> ScriptHTTPResponse
}
