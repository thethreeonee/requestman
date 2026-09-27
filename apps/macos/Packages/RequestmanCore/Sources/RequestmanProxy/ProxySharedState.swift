import Foundation
import NIOCore
import NIOSSL
import RequestmanCertificates
import RequestmanCore
import os

final class ProxySharedState: Sendable {
    static let maximumConnections = 256
    let replays = OSAllocatedUnfairLock(initialState: [UUID: ProxyReplaySession]())
    func replaySession(for channel: Channel) -> ProxyReplaySession? {
        guard let host = channel.remoteAddress?.ipAddress, LocalNetwork.isLoopback(host),
              let port = channel.remoteAddress?.port else { return nil }
        return replays.withLock { $0.values.first { $0.clientPort == port } }
    }
    let events = CaptureEventBuffer()
    let ruleHitNotifications = RuleHitNotificationBuffer()
    let tlsContexts = ProxyTLSContexts()
    let certificateProvider: (any TLSCertificateProviding)?
    let upstreamTrustRoots: [NIOSSLCertificate]?
    init(certificateProvider: (any TLSCertificateProviding)? = nil, upstreamTrustRoots: [NIOSSLCertificate]? = nil) {
        self.certificateProvider = certificateProvider
        self.upstreamTrustRoots = upstreamTrustRoots
    }
    let configuration = OSAllocatedUnfairLock(initialState: ExplicitProxyConfiguration())
    let document = OSAllocatedUnfairLock(initialState: WorkspaceDocument())
    private struct Connections {
        var accepting = true
        var downstream: [ObjectIdentifier: Channel] = [:]
        var upstream: [ObjectIdentifier: Channel] = [:]
    }
    private let connections = OSAllocatedUnfairLock(initialState: Connections())
    var isStopping: Bool { connections.withLock { !$0.accepting } }
    func prepareForStart() { connections.withLock { $0.accepting = true } }
    func beginShutdown() -> [Channel] {
        connections.withLock {
            $0.accepting = false
            // Downstream cancellation records incomplete transactions before upstream teardown.
            return Array($0.downstream.values) + Array($0.upstream.values)
        }
    }
    func register(_ channel: Channel, downstream: Bool = true) -> Bool {
        let registered = connections.withLock { connections in
            guard connections.accepting else { return false }
            if downstream {
                guard connections.downstream.count < Self.maximumConnections else { return false }
                connections.downstream[ObjectIdentifier(channel)] = channel
            } else {
                connections.upstream[ObjectIdentifier(channel)] = channel
            }
            return true
        }
        if registered { channel.closeFuture.whenComplete { [self] _ in unregister(channel) } }
        return registered
    }
    private func unregister(_ channel: Channel) {
        connections.withLock {
            $0.downstream.removeValue(forKey: ObjectIdentifier(channel))
            $0.upstream.removeValue(forKey: ObjectIdentifier(channel))
        }
    }
}
