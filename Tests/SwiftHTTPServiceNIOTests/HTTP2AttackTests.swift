import Foundation
import NIOConcurrencyHelpers
import NIOPosix
import SwiftHTTPService
import SwiftTLSKit
import SwiftTLSKitTestSupport
import Testing
@testable import SwiftHTTPServiceNIO

/// What the server does with the HTTP/2 attacks that are not a single bad request but a flood of frames.
///
/// Every test sends the frames by hand. The expected reaction is a GOAWAY, or the connection closed, and for
/// the floods the code RFC 9113 section 7 names for a peer that is being excessive, `ENHANCE_YOUR_CALM` (11);
/// the handler must also never have run, since none of these is a request. Which defence is the library's and
/// which is this package's is recorded in the changelog, from what these tests measured.
@Suite("HTTP/2 attacks and shutdown", .serialized)
struct HTTP2AttackTests {

    static let enhanceYourCalm: UInt32 = 11
    static let protocolError: UInt32 = 1
    static let refusedStream: UInt32 = 7

    private func withServer<T>(
        limits: Limits = Limits(), handler: @escaping Handler = ok(),
        _ body: (Running, TestTLS, MultiThreadedEventLoopGroup) async throws -> T
    ) async throws -> T {
        let material = try TestTLS()
        defer { material.cleanUp() }
        let running = try await startServer(limits: limits, tls: material.files, handler: handler)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let result: T
        do { result = try await body(running, material, group) } catch {
            try? await group.shutdownGracefully()
            await running.server.shutdown()
            throw error
        }
        try await group.shutdownGracefully()
        await running.server.shutdown()
        return result
    }

    private func connect(_ running: Running, _ material: TestTLS, _ group: MultiThreadedEventLoopGroup) async throws -> RawH2 {
        let connection = try await RawH2.connect(to: running.address, group: group, tls: try material.clientContext(applicationProtocols: ["h2"]))
        // The server's SETTINGS come first; acknowledge them as a conforming client would.
        #expect(try await connection.wait { $0.contains { $0.type == H2Wire.FrameType.settings.rawValue && !$0.isSettingsAck } })
        try await connection.send(H2Wire.settingsAck)
        return connection
    }

    // MARK: What is advertised

    @Test("The SETTINGS the server sends carry the configured stream and header-list bounds")
    func advertisedSettings() async throws {
        var limits = Limits()
        limits.maximumConcurrentStreams = 7
        limits.maximumHeaderBytes = 4096
        try await withServer(limits: limits) { running, material, group in
            let connection = try await connect(running, material, group)
            let pairs = connection.frames.flatMap(\.settingPairs)
            // RFC 9113 section 6.5.2: SETTINGS_MAX_CONCURRENT_STREAMS is 3, SETTINGS_MAX_HEADER_LIST_SIZE is 6.
            #expect(pairs.first { $0.0 == 3 }?.1 == 7)
            #expect(pairs.first { $0.0 == 6 }?.1 == 4096)
            await connection.close()
        }
    }

    // MARK: Streams past the bound

    @Test("A stream opened past the concurrent bound by a client that ignores it is refused; the earlier ones are left alone")
    func overLimitStream() async throws {
        var limits = Limits()
        limits.maximumConcurrentStreams = 2
        try await withServer(limits: limits) { running, material, group in
            let connection = try await connect(running, material, group)
            // Streams 1 and 3 are held open (no END_STREAM, so the server is waiting for a body that never comes).
            try await connection.send(
                H2Wire.headers(stream: 1, block: [0x83, 0x87, 0x84], endStream: false)
                + H2Wire.headers(stream: 3, block: [0x83, 0x87, 0x84], endStream: false)
                + H2Wire.headers(stream: 5, block: [0x83, 0x87, 0x84], endStream: false))
            // RFC 9113 section 5.1.2: exceeding the bound is a stream error of PROTOCOL_ERROR or REFUSED_STREAM.
            let refused = try await connection.wait { frames in
                frames.contains { $0.type == H2Wire.FrameType.rstStream.rawValue && $0.stream == 5 && [Self.protocolError, Self.refusedStream].contains($0.errorCode ?? 99) }
                    || frames.contains { $0.type == H2Wire.FrameType.goAway.rawValue }
            }
            #expect(refused)
            let resets = connection.frames.filter { $0.type == H2Wire.FrameType.rstStream.rawValue }.map(\.stream)
            #expect(!resets.contains(1) && !resets.contains(3))
            await connection.close()
        }
    }

    // MARK: Floods

    @Test("Control: a handful of pings, of opened-and-cancelled streams, and a real request are all served, so the floods below are refused for their volume")
    func modestTrafficIsNotRefused() async throws {
        try await withServer(handler: ok("fine")) { running, material, group in
            let connection = try await connect(running, material, group)
            var traffic: [UInt8] = []
            for index in 0..<5 { traffic += H2Wire.ping(UInt8(index)) }
            for index in 0..<5 {
                let stream = UInt32(index * 2 + 1)
                traffic += H2Wire.headers(stream: stream, endStream: false) + H2Wire.rstStream(stream, code: 8)
            }
            traffic += H2Wire.headers(stream: 11, endStream: true)
            try await connection.send(traffic)
            #expect(try await connection.wait { frames in
                frames.contains { $0.type == H2Wire.FrameType.headers.rawValue && $0.stream == 11 && $0.payload.first == 0x88 }
            })
            let acks = connection.frames.filter { $0.type == H2Wire.FrameType.ping.rawValue && $0.flags & H2Wire.ack != 0 }
            #expect(acks.count == 5)
            #expect(!connection.frames.contains { $0.type == H2Wire.FrameType.goAway.rawValue })
            #expect(!connection.isClosed)
            await connection.close()
        }
    }

    /// Whether the reaction is a GOAWAY carrying one of `codes`. A bare close is not enough (it could be
    /// anything, a TLS fault included), and silence means the flood was absorbed. RFC 9113 section 7 names
    /// ENHANCE_YOUR_CALM for a peer that is excessive and PROTOCOL_ERROR for one that is malformed.
    private func isCalm(_ refusal: RawRefusal, codes: [UInt32] = [enhanceYourCalm, protocolError]) -> Bool {
        guard case .goAway(let code) = refusal else { return false }
        return codes.contains(code)
    }

    @Test("Rapid reset: a thousand streams opened and cancelled at once ends the connection, and no handler runs")
    func rapidReset() async throws {
        let ran = NIOLockedValueBox(0)
        try await withServer(handler: { _ in
            ran.withLockedValue { $0 += 1 }
            return Response(status: .ok)
        }) { running, material, group in
            let connection = try await connect(running, material, group)
            var burst: [UInt8] = []
            for index in 0..<1000 {
                let stream = UInt32(index * 2 + 1)
                burst += H2Wire.headers(stream: stream, endStream: false) + H2Wire.rstStream(stream, code: 8)   // CANCEL
            }
            try? await connection.send(burst)
            let refusal = try await connection.waitForRefusal()
            #expect(isCalm(refusal), "saw \(refusal)")
            #expect(ran.withLockedValue { $0 } == 0)
            await connection.close()
        }
    }

    @Test("A header block that never ends, in many small CONTINUATION frames, ends the connection")
    func continuationFloodSmall() async throws {
        let ran = NIOLockedValueBox(0)
        try await withServer(handler: { _ in ran.withLockedValue { $0 += 1 }; return Response(status: .ok) }) { running, material, group in
            let connection = try await connect(running, material, group)
            var burst = H2Wire.headers(stream: 1, block: [0x82], endStream: true, endHeaders: false)
            for _ in 0..<5000 { burst += H2Wire.continuation(stream: 1, block: [0x82]) }
            try? await connection.send(burst)
            let refusal = try await connection.waitForRefusal()
            #expect(isCalm(refusal), "saw \(refusal)")
            #expect(ran.withLockedValue { $0 } == 0)
            await connection.close()
        }
    }

    @Test("A header block that never ends, in a few huge CONTINUATION frames, ends the connection before it is buffered whole")
    func continuationFloodLarge() async throws {
        var limits = Limits()
        limits.maximumHeaderBytes = 1024
        try await withServer(limits: limits) { running, material, group in
            let connection = try await connect(running, material, group)
            var burst = H2Wire.headers(stream: 1, block: [0x82], endStream: true, endHeaders: false)
            for _ in 0..<64 { burst += H2Wire.continuation(stream: 1, block: [UInt8](repeating: 0x00, count: 16_384)) }   // 1 MiB in all
            try? await connection.send(burst)
            let refusal = try await connection.waitForRefusal()
            #expect(isCalm(refusal), "saw \(refusal)")
            await connection.close()
        }
    }

    @Test("A flood of PING frames ends the connection")
    func pingFlood() async throws {
        try await withServer { running, material, group in
            let connection = try await connect(running, material, group)
            var burst: [UInt8] = []
            for index in 0..<1000 { burst += H2Wire.ping(UInt8(index & 0xFF)) }
            try? await connection.send(burst)
            let refusal = try await connection.waitForRefusal()
            #expect(isCalm(refusal), "saw \(refusal)")
            await connection.close()
        }
    }

    @Test("A flood of SETTINGS frames ends the connection")
    func settingsFlood() async throws {
        try await withServer { running, material, group in
            let connection = try await connect(running, material, group)
            var burst: [UInt8] = []
            for _ in 0..<1000 { burst += H2Wire.settings() }
            try? await connection.send(burst)
            let refusal = try await connection.waitForRefusal()
            #expect(isCalm(refusal), "saw \(refusal)")
            await connection.close()
        }
    }

    @Test("A run of empty DATA frames on an open stream ends the connection")
    func emptyDataFlood() async throws {
        try await withServer { running, material, group in
            let connection = try await connect(running, material, group)
            var burst = H2Wire.headers(stream: 1, block: [0x83, 0x87, 0x84], endStream: false)
            for _ in 0..<200 { burst += H2Wire.data(stream: 1) }
            try? await connection.send(burst)
            let refusal = try await connection.waitForRefusal()
            #expect(isCalm(refusal), "saw \(refusal)")
            await connection.close()
        }
    }

    // MARK: Shutdown

    @Test("Shutting down tells an idle h2 connection with GOAWAY(NO_ERROR) and then closes it")
    func goAwayOnShutdown() async throws {
        try await withServer { running, material, group in
            let connection = try await connect(running, material, group)
            let shutdown = Task { await running.server.shutdown() }
            let pings = Task { try await connection.answerPings() }
            let goAway = try await connection.wait { $0.contains { $0.type == H2Wire.FrameType.goAway.rawValue } }
            #expect(goAway)
            #expect(connection.frames.first { $0.type == H2Wire.FrameType.goAway.rawValue }?.errorCode == 0)
            #expect(try await client(connection, closesWithin: .seconds(3)))
            _ = try await pings.value
            await shutdown.value
            await connection.close()
        }
    }

    @Test("A request in flight when shutdown begins is answered before the connection closes")
    func inFlightFinishes() async throws {
        let gate = HoldGate()
        try await withServer(handler: { _ in
            await gate.wait()
            return Response(status: .ok, body: Data("done".utf8))
        }) { running, material, group in
            let connection = try await connect(running, material, group)
            try await connection.send(H2Wire.headers(stream: 1, endStream: true))
            try await Task.sleep(for: .milliseconds(200))                    // the request is in the handler
            let shutdown = Task { await running.server.shutdown() }
            let pings = Task { try await connection.answerPings(timeout: .seconds(5)) }
            #expect(try await connection.wait { $0.contains { $0.type == H2Wire.FrameType.goAway.rawValue } })
            #expect(!connection.isClosed)                                     // told, and not yet cut off
            await gate.release()
            // The response: a HEADERS frame on stream 1 whose first octet is 0x88, ":status 200" from the static table.
            #expect(try await connection.wait { $0.contains { $0.type == H2Wire.FrameType.headers.rawValue && $0.stream == 1 && $0.payload.first == 0x88 } })
            #expect(try await client(connection, closesWithin: .seconds(3)))
            _ = try await pings.value
            await shutdown.value
            await connection.close()
        }
    }

    @Test("A handler that never returns is cut off at the end of the grace period, shutdown still completes, and the handler finishing later touches no stopped loop")
    func graceEnds() async throws {
        var limits = Limits()
        limits.shutdownGrace = .milliseconds(300)
        let gate = HoldGate()
        let captured = try await captureStandardError {
            try await withServer(limits: limits, handler: { _ in
                await gate.wait()
                return Response(status: .ok)
            }) { running, material, group in
                let connection = try await connect(running, material, group)
                try await connection.send(H2Wire.headers(stream: 1, endStream: true))
                try await Task.sleep(for: .milliseconds(200))
                let started = ContinuousClock.now
                await running.server.shutdown()
                #expect(ContinuousClock.now - started < .seconds(5))
                #expect(try await client(connection, closesWithin: .seconds(3)))
                await gate.release()                                       // the handler returns, to nobody
                try await Task.sleep(for: .milliseconds(200))
                await connection.close()
            }
        }
        #expect(!captured.contains("already shut down"), "standard error said: \(captured)")
    }

    private func client(_ connection: RawH2, closesWithin timeout: Duration) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if connection.isClosed { return true }
            try await Task.sleep(for: .milliseconds(5))
        }
        return connection.isClosed
    }
}
