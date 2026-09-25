import Foundation
import NIOCore
import NIOPosix
import Testing
import RequestmanCore
@testable import RequestmanProxy

struct UpstreamProxyProbeTests {
    @Test func acceptsReachableEndpointAndClosesProbeConnection() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let closed = group.next().makePromise(of: Void.self)
        let listener = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            channel.closeFuture.cascade(to: closed)
            return channel.eventLoop.makeSucceededFuture(())
        }.bind(host: "127.0.0.1", port: 0).get()
        do {
            let endpoint = ProxyEndpoint(host: "127.0.0.1", port: try #require(listener.localAddress?.port))
            try await UpstreamProxyProbe.check(endpoint)
            let watchdog = group.next().scheduleTask(in: .seconds(4)) { closed.fail(WorkflowError.invalid("Probe connection was not closed")) }
            do { try await closed.futureResult.get() }
            catch { watchdog.cancel(); throw error }
            watchdog.cancel()
            try await listener.close().get()
            try await group.shutdownGracefully()
        } catch {
            try? await listener.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    @Test func closedPortFailsWithinDeadline() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let listener = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        let port = try #require(listener.localAddress?.port)
        try await listener.close().get()
        try await group.shutdownGracefully()
        let start = ContinuousClock.now
        await #expect(throws: (any Error).self) {
            try await UpstreamProxyProbe.check(ProxyEndpoint(host: "127.0.0.1", port: port), timeout: .milliseconds(150))
        }
        #expect(start.duration(to: .now) < .seconds(2))
    }

    @Test func alreadyCancelledCheckDoesNotConnect() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await UpstreamProxyProbe.check(ProxyEndpoint(host: "127.0.0.1", port: 6152))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func invalidEndpointFailsBeforeConnectionSetup() async {
        await #expect(throws: CaptureConfigurationError.self) {
            try await UpstreamProxyProbe.check(ProxyEndpoint(host: "127.0.0.1", port: 70000))
        }
    }

    @Test func cancellingPendingCheckDoesNotWaitForDeadline() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let listener = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        let port = try #require(listener.localAddress?.port)
        try await listener.close().get()
        try await group.shutdownGracefully()
        let task = Task {
            try await UpstreamProxyProbe.check(ProxyEndpoint(host: "127.0.0.1", port: port), timeout: .seconds(30))
        }
        try await Task.sleep(for: .milliseconds(20))
        let cancelledAt = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(cancelledAt.duration(to: .now) < .seconds(2))
    }
}
