import Foundation
import NIOCore
import NIOSSL
import RequestmanCertificates
import Security

/// TLS transport only; the HTTP workflow remains in ProxyConnection.
enum ProxyTLS {
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
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.minimumTLSVersion = .tlsv12
        configuration.applicationProtocols = ["http/1.1"]
        // Security validates the target hostname below. NIOSSL must not compare an IP
        // target to the HTTP upstream proxy's socket address a second time.
        configuration.certificateVerification = .noHostnameVerification
        // macOS Security performs hostname, validity and system/user trust validation below.
        // These empty BoringSSL roots are not used by the custom verification callback.
        configuration.trustRoots = .certificates([])
        let anchors = try testTrustRoots?.map { Data(try $0.toDERBytes()) }
        let sni = (try? SocketAddress(ipAddress: name, port: 443)) == nil ? name : nil
        return try NIOSSLClientHandler(
            context: NIOSSLContext(configuration: configuration), serverHostname: sni,
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
