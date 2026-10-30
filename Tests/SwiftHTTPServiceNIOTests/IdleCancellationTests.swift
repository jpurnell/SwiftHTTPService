import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import SwiftHTTPService
import Testing
@testable import SwiftHTTPServiceNIO

/// Records when work that is waiting notices it has been cancelled. Shared by the handler and the test.
final class CancellationProbe: Sendable {
    private let started = NIOLockedValueBox(false)
    private let cancelledAt = NIOLockedValueBox<ContinuousClock.Instant?>(nil)

    func markStarted() { started.withLockedValue { $0 = true } }
    var hasStarted: Bool { started.withLockedValue { $0 } }
    func markCancelled() { cancelledAt.withLockedValue { if $0 == nil { $0 = .now } } }
    var wasCancelled: Bool { cancelledAt.withLockedValue { $0 != nil } }

    /// Sits idle, checking for cancellation, for at most `limit`; this is what an idle handler does.
    func idle(limit: Duration = .seconds(8)) async {
        markStarted()
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
            if Task.isCancelled { markCancelled(); return }
        }
    }

    /// Waits for the work to start.
    func waitStarted() async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if hasStarted { return true }
            try await Task.sleep(for: .milliseconds(5))
        }
        return hasStarted
    }

    /// Waits up to `window` for a cancellation; true if it came.
    func waitCancelled(within window: Duration) async throws -> Bool {
        let deadline = ContinuousClock.now + window
        while ContinuousClock.now < deadline {
            if wasCancelled { return true }
            try await Task.sleep(for: .milliseconds(5))
        }
        return wasCancelled
    }
}

/// Spike S1 (item K4): when a client leaves while the application is idle, the application's task is cancelled
/// promptly. "Idle" means the handler is suspended, or a streaming producer is between writes: not reading a
/// body, not writing a response.
@Suite("Idle handlers are cancelled when the client leaves", .serialized)
struct IdleCancellationTests {
    private static let window = Duration.seconds(1)
    private static let request = "GET /x HTTP/1.1\r\nHost: localhost\r\n\r\n"

    private func idleHandler(_ probe: CancellationProbe) -> Handler {
        { _ in
            await probe.idle()
            return Response(status: .ok, body: Data("late".utf8))
        }
    }

    private func idleProducer(_ probe: CancellationProbe) -> Handler {
        { _ in
            .streaming(status: .ok) { writer in
                try await writer.write(Data("first".utf8))
                await probe.idle()
            }
        }
    }

    private func http1(_ connections: ServiceConfiguration.ConnectionReuse, handler: @escaping Handler, leave: (RawClient) async throws -> Void, probe: CancellationProbe) async throws -> Bool {
        let server = HTTPServer(configuration: try ServiceConfiguration(port: 0, connectionReuse: connections), handler: handler)
        let address = try await server.start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let cancelled: Bool
        do {
            let client = try await RawClient.connect(to: address, group: group)
            try await client.send(Self.request)
            guard try await probe.waitStarted() else { throw ChannelError.ioOnClosedChannel }
            try await Task.sleep(for: .milliseconds(200))       // the handler is idle by now
            try await leave(client)
            cancelled = try await probe.waitCancelled(within: Self.window)
        } catch {
            try? await group.shutdownGracefully()
            await server.shutdown()
            throw error
        }
        try await group.shutdownGracefully()
        await server.shutdown()
        return cancelled
    }

    @Test("HTTP/1.1 keep-alive: a client that closes while the handler is idle cancels it")
    func http1KeepAlive() async throws {
        let probe = CancellationProbe()
        let cancelled = try await http1(.keepAlive, handler: idleHandler(probe), leave: { await $0.close() }, probe: probe)
        #expect(cancelled)
    }

    @Test("HTTP/1.1 closeAfterResponse: a client that closes while the handler is idle cancels it")
    func http1CloseAfterResponse() async throws {
        let probe = CancellationProbe()
        let cancelled = try await http1(.closeAfterResponse, handler: idleHandler(probe), leave: { await $0.close() }, probe: probe)
        #expect(cancelled)
    }

    @Test("HTTP/1.1: a client that only half-closes (sends FIN, keeps reading) cancels an idle handler")
    func http1HalfClose() async throws {
        let probe = CancellationProbe()
        let cancelled = try await http1(.keepAlive, handler: idleHandler(probe), leave: { client in
            try await client.channel.close(mode: .output).get()
        }, probe: probe)
        #expect(cancelled)
    }

    @Test("HTTP/1.1: a streaming producer that is idle between writes is cancelled when the client closes")
    func http1Producer() async throws {
        for connections in [ServiceConfiguration.ConnectionReuse.keepAlive, .closeAfterResponse] {
            let probe = CancellationProbe()
            let cancelled = try await http1(connections, handler: idleProducer(probe), leave: { await $0.close() }, probe: probe)
            #expect(cancelled, "\(connections)")
        }
    }

    private func http2<T>(handler: @escaping Handler, _ body: (H2Client) async throws -> T) async throws -> T {
        let material = try TestTLS()
        defer { material.cleanUp() }
        let server = HTTPServer(configuration: try ServiceConfiguration(port: 0, tls: material.files), handler: handler)
        let address = try await server.start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let result: T
        do {
            let client = try await H2Client.connect(to: address, group: group, tls: try material.clientContext(applicationProtocols: ["h2"]))
            result = try await body(client)
        } catch {
            try? await group.shutdownGracefully()
            await server.shutdown()
            throw error
        }
        try await group.shutdownGracefully()
        await server.shutdown()
        return result
    }

    @Test("HTTP/2: a client that resets the stream while the handler is idle cancels it")
    func http2StreamReset() async throws {
        let probe = CancellationProbe()
        try await http2(handler: idleHandler(probe)) { client in
            let stream = try await client.open("GET", "/x")
            #expect(try await probe.waitStarted())
            try await Task.sleep(for: .milliseconds(200))
            await stream.reset()
            #expect(try await probe.waitCancelled(within: Self.window))
            await client.close()
        }
    }

    @Test("HTTP/2: a client that closes the connection while the handler is idle cancels it")
    func http2ConnectionClose() async throws {
        let probe = CancellationProbe()
        try await http2(handler: idleHandler(probe)) { client in
            _ = try await client.open("GET", "/x")
            #expect(try await probe.waitStarted())
            try await Task.sleep(for: .milliseconds(200))
            await client.close()
            #expect(try await probe.waitCancelled(within: Self.window))
        }
    }

    @Test("HTTP/2: an idle streaming producer is cancelled when the client resets the stream, and when it closes the connection")
    func http2Producer() async throws {
        for resetsStream in [true, false] {
            let probe = CancellationProbe()
            try await http2(handler: idleProducer(probe)) { client in
                let stream = try await client.open("GET", "/x")
                #expect(try await stream.wait { $0.text == "first" })
                #expect(try await probe.waitStarted())
                try await Task.sleep(for: .milliseconds(200))
                if resetsStream { await stream.reset() } else { await client.close() }
                #expect(try await probe.waitCancelled(within: Self.window), "resetsStream: \(resetsStream)")
                await client.close()
            }
        }
    }
}
