import Foundation
import Security

/// The legacy file-keychain UI switch is process-wide. All certificate operations,
/// including setup and signing, share this lock and never suspend inside the scope.
/// Do not use this scope around unrelated network or UI work.
enum CertificateKeychainInteraction {
    private static let lock = NSRecursiveLock()

    static func perform<T>(allowingUI: Bool, _ body: () throws -> T) throws -> T {
        try lock.withLock {
            var previous = DarwinBoolean(false)
            try check(SecKeychainGetUserInteractionAllowed(&previous))
            try check(SecKeychainSetUserInteractionAllowed(allowingUI))
            let result: Result<T, Error>
            do { result = .success(try body()) }
            catch { result = .failure(error) }
            try check(SecKeychainSetUserInteractionAllowed(previous.boolValue))
            return try result.get()
        }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw LocalCertificateError.security(operation: "设置证书授权交互", status: status)
        }
    }
}
