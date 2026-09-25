import Foundation
import NIOCore
import NIOSSL
import RequestmanCertificates
import Security
import os

/// Cache identities, not trust decisions. The provider authorizes every lease first.
final class ProxyTLSContexts: Sendable {
    private let servers = OSAllocatedUnfairLock(initialState: [Data: NIOSSLContext]())

    func server(_ identity: TLSCertificateIdentity) throws -> NIOSSLContext {
        try servers.withLock { contexts in
            if let context = contexts[identity.certificateDER] { return context }
            let context = try ProxyTLS.serverContext(identity)
            if contexts.count >= 128, let key = contexts.keys.first { contexts.removeValue(forKey: key) }
            contexts[identity.certificateDER] = context
            return context
        }
    }
}

/// TLS transport only; the HTTP workflow remains in ProxyConnection.
enum ProxyTLS {
    /// NSError's default bridge loses the TLS case and underlying BoringSSL alert.
    static func errorDescription(_ error: Error) -> String {
        if let tlsError = error as? NIOSSLError {
            switch tlsError {
            case .handshakeFailed(let reason):
                return "TLS 握手失败：\(reason)"
            case .shutdownFailed(let reason):
                return "TLS 关闭失败：\(reason)"
            case .uncleanShutdown:
                return "对端未发送 TLS 关闭通知就断开了连接（uncleanShutdown）"
            default:
                return String(describing: tlsError)
            }
        }
        if error is NIOSSLExtraError { return String(describing: error) }
        return error.localizedDescription
    }

    private static let clientContext: Result<NIOSSLContext, Error> = Result {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.minimumTLSVersion = .tlsv12
        configuration.applicationProtocols = ["http/1.1"]
        configuration.certificateVerification = .noHostnameVerification
        configuration.trustRoots = .certificates([])
        return try NIOSSLContext(configuration: configuration)
    }
    static func serverContext(_ identity: TLSCertificateIdentity) throws -> NIOSSLContext {
        let certificate = try NIOSSLCertificate(bytes: Array(identity.certificateDER), format: .der)
        let key = try NIOSSLPrivateKey(bytes: Array(identity.privateKeyPEM), format: .pem)
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(certificate)], privateKey: .privateKey(key)
        )
        configuration.minimumTLSVersion = .tlsv12
        configuration.applicationProtocols = ["http/1.1"]
        return try NIOSSLContext(configuration: configuration)
    }

    static func client(host: String, testTrustRoots: [NIOSSLCertificate]?) throws -> NIOSSLClientHandler {
        let name = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        // Security validates the target hostname below. NIOSSL must not compare an IP
        // target to the HTTP upstream proxy's socket address a second time.
        // macOS Security performs hostname, validity and system/user trust validation below.
        // These empty BoringSSL roots are not used by the custom verification callback.
        let anchors = try testTrustRoots?.map { Data(try $0.toDERBytes()) }
        let sni = (try? SocketAddress(ipAddress: name, port: 443)) == nil ? name : nil
        return try NIOSSLClientHandler(
            context: clientContext.get(), serverHostname: sni,
            customVerificationCallback: { certificates, promise in
                do {
                    let chain = try certificates.map { Data(try $0.toDERBytes()) }
                    DispatchQueue.global(qos: .userInitiated).async {
                        promise.succeed(verify(chain: chain, host: name, testAnchors: anchors) ? .certificateVerified : .failed)
                    }
                } catch { promise.fail(error) }
            }
        )
    }

    private static func verify(chain: [Data], host: String, testAnchors: [Data]?) -> Bool {
        let certificates = chain.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard !certificates.isEmpty, certificates.count == chain.count else { return false }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateSSL(true, host as CFString), &trust) == errSecSuccess,
              let trust else { return false }
        // Never fetch through the system proxy (which may point back at Requestman).
        guard SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess else { return false }
        if let testAnchors {
            let anchors = testAnchors.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
            guard anchors.count == testAnchors.count,
                  SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else { return false }
        }
        return SecTrustEvaluateWithError(trust, nil)
    }
}
