import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import SwiftHTTPService
import Testing
@testable import SwiftHTTPServiceNIO

/// Every timeout the README documents, proved over a real socket: what the client sees, and how soon.
///
/// The documented behaviour (README, "Limits"): `headerReadTimeout` and `bodyReadTimeout` answer `408` and close;
/// `idleTimeout` closes with nothing written, between requests and before the first byte; `streamWriteTimeout` ends a
/// stream whose peer does not read. The TLS handshake has no row in the README; the source (PipelineBuilder) bounds it
/// by `idleTimeout`, and that is what is asserted.
///
/// Time bounds. Every limit here is 300 ms. A timer cannot fire early, and the client's clock starts before the server's,
/// so the lower bound is the limit less 5 ms (the client polls every 5 ms). The upper bound is the limit plus one second;
/// the observed latencies are printed as `RIG-MEASURE` lines (see RigFindings.md for the numbers measured on the
/// development machine).
@Suite("Timeouts over a real socket", .serialized)
struct TimeoutRefusalTests {
    private static let limit = Duration.milliseconds(300)
    private static let slack = Duration.seconds(1)

    private func short() -> Limits {
        var limits = Limits()
        limits.headerReadTimeout = Self.limit
        limits.bodyReadTimeout = Self.limit
        limits.idleTimeout = Self.limit
        limits.streamWriteTimeout = Self.limit
        return limits
    }

    private func withServer<T>(
        tls: TestTLS? = nil, handler: @escaping Handler = ok(),
        _ body: (Running, MultiThreadedEventLoopGroup) async throws -> T
    ) async throws -> T {
        let running = try await startServer(limits: short(), tls: tls?.files, handler: handler)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let result: T
        do { result = try await body(running, group) } catch {
            try? await group.shutdownGracefully()
            await running.server.shutdown()
            throw error
        }
        try await group.shutdownGracefully()
        await running.server.shutdown()
        return result
    }

    private func expectWithinBounds(_ elapsed: Duration, _ name: String) {
        recordMeasurement(name, "\(elapsed.seconds) s")
        // TIMING: these are timeout tests; the elapsed time is the quantity under test, against the configured limit.
        #expect(elapsed >= Self.limit - .milliseconds(5), "\(name) fired early: \(elapsed)")
        // TIMING: the upper bound is the documented limit plus a second of scheduling slack.
        #expect(elapsed <= Self.limit + Self.slack, "\(name) fired late: \(elapsed)")
    }

    // MARK: HTTP/1.1

    @Test("A client that connects and sends nothing is closed after the idle timeout, with nothing written")
    func silentConnection() async throws {
        try await withServer { running, group in
            let client = try await RawClient.connect(to: running.address, group: group)
            let began = ContinuousClock.now
            #expect(try await client.waitUntilClosed(timeout: .seconds(5)))
            expectWithinBounds(ContinuousClock.now - began, "silent connection closed after")
            #expect(client.received.isEmpty, "documented: nothing is written")
        }
    }

    @Test("A client that sends a partial head and stops gets 408 and a close after the header timeout")
    func partialHead() async throws {
        try await withServer { running, group in
            let client = try await RawClient.connect(to: running.address, group: group)
            let began = ContinuousClock.now
            try await client.send("GET /x HTTP/1.1\r\nHost: h\r\nX-Slow: ")
            let response = try await client.response(timeout: .seconds(5))
            let elapsed = ContinuousClock.now - began
            #expect(response?.status == 408)
            #expect(response?.values("connection") == ["close"])
            expectWithinBounds(elapsed, "partial head answered 408 after")
            #expect(try await client.waitUntilClosed(timeout: .seconds(2)))
        }
    }

    @Test("A head dripped a byte at a time does not extend the deadline: 408 arrives by the header timeout, not by the last byte")
    func drippedHead() async throws {
        try await withServer { running, group in
            let client = try await RawClient.connect(to: running.address, group: group)
            let began = ContinuousClock.now
            // A byte every 100 ms would keep a per-read timer alive for ever; the deadline is on the whole head.
            let drip = Task {
                for byte in "GET /x HTTP/1.1\r\nHost: h\r\nX-Slow: aaaaaaaaaaaaaaaaaaaa".utf8 {
                    if client.isClosed || Task.isCancelled { return }
                    try? await client.send(String(decoding: [byte], as: UTF8.self))
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            let response = try await client.response(timeout: .seconds(5))
            drip.cancel()
            let elapsed = ContinuousClock.now - began
            #expect(response?.status == 408)
            expectWithinBounds(elapsed, "dripped head answered 408 after")
        }
    }

    @Test("A client that sends a head with Content-Length and part of the body gets 408 and a close after the body timeout")
    func partialBody() async throws {
        try await withServer(handler: { _ in Response(status: .ok) }) { running, group in
            let client = try await RawClient.connect(to: running.address, group: group)
            try await client.send("POST /x HTTP/1.1\r\nHost: h\r\nContent-Length: 10\r\n\r\nabc")
            let began = ContinuousClock.now
            let response = try await client.response(timeout: .seconds(5))
            let elapsed = ContinuousClock.now - began
            #expect(response?.status == 408)
            #expect(response?.values("connection") == ["close"])
            expectWithinBounds(elapsed, "partial body answered 408 after")
            #expect(try await client.waitUntilClosed(timeout: .seconds(2)))
        }
    }

    @Test("An idle keep-alive connection is closed after the idle timeout, nothing further written")
    func idleKeepAlive() async throws {
        try await withServer { running, group in
            let client = try await RawClient.connect(to: running.address, group: group)
            try await client.send("GET /x HTTP/1.1\r\nHost: h\r\n\r\n")
            let first = try await client.response(timeout: .seconds(5))
            #expect(first?.status == 200)
            let written = client.received.count
            let began = ContinuousClock.now
            #expect(try await client.waitUntilClosed(timeout: .seconds(5)))
            expectWithinBounds(ContinuousClock.now - began, "idle keep-alive closed after")
            #expect(client.received.count == written, "documented: nothing is written when the idle timeout closes")
        }
    }

    // MARK: TLS

    @Test("A TLS server closes a client that connects and never starts the handshake, after the idle timeout")
    func handshakeSilent() async throws {
        let material = try TestTLS()
        defer { material.cleanUp() }
        try await withServer(tls: material) { running, group in
            let client = try await RawClient.connect(to: running.address, group: group)       // plain TCP: no ClientHello
            let began = ContinuousClock.now
            #expect(try await client.waitUntilClosed(timeout: .seconds(5)))
            expectWithinBounds(ContinuousClock.now - began, "TLS handshake (silent) closed after")
        }
    }

    @Test("A TLS server closes a client that sends part of a ClientHello and stops, after the idle timeout")
    func handshakePartial() async throws {
        let material = try TestTLS()
        defer { material.cleanUp() }
        try await withServer(tls: material) { running, group in
            let client = try await RawClient.connect(to: running.address, group: group)
            // A TLS record header (RFC 8446 section 5.1): handshake (22), legacy version 3.1, length 512; then no payload.
            try await client.channel.writeAndFlush(ByteBuffer(bytes: [0x16, 0x03, 0x01, 0x02, 0x00, 0x01])).get()
            let began = ContinuousClock.now
            #expect(try await client.waitUntilClosed(timeout: .seconds(5)))
            expectWithinBounds(ContinuousClock.now - began, "TLS handshake (partial hello) closed after")
        }
    }

    // MARK: Streaming

    @Test("HTTP/1.1: a peer that stops reading a streaming response has the stream ended after the write timeout; the client sees a truncated body, then the close")
    func stalledReaderHTTP1() async throws {
        let failedAt = NIOLockedValueBox<ContinuousClock.Instant?>(nil)
        let writeBeganAt = NIOLockedValueBox<ContinuousClock.Instant?>(nil)
        let big = Data(repeating: 0x61, count: 1 << 20)
        try await withServer(handler: { _ in
            .streaming(status: .ok) { writer in
                do {
                    for _ in 0..<512 {
                        writeBeganAt.withLockedValue { $0 = .now }        // the write in progress when it fails is the last one begun
                        try await writer.write(big)
                    }
                } catch { failedAt.withLockedValue { $0 = .now } }
            }
        }) { running, group in
            let client = try await RawClient.connect(to: running.address, group: group)
            try await client.channel.setOption(ChannelOptions.autoRead, value: false).get()
            try await client.send("GET /x HTTP/1.1\r\nHost: h\r\n\r\n")
            let deadline = ContinuousClock.now + .seconds(15)
            while failedAt.withLockedValue({ $0 }) == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            let failed = try #require(failedAt.withLockedValue { $0 }, "the producer was never told the write failed")
            let last = try #require(writeBeganAt.withLockedValue { $0 }, "no write ever began")
            // The write that could not finish was abandoned one timeout after it began.
            expectWithinBounds(failed - last, "HTTP/1.1 stalled write abandoned after")
            // Now read: the client sees the connection end without the chunked terminator (a truncated body).
            try await client.channel.setOption(ChannelOptions.autoRead, value: true).get()
            client.channel.read()
            #expect(try await client.waitUntilClosed(timeout: .seconds(10)), "the server must close the connection")
            #expect(!client.received.suffix(5).elementsEqual(Data("0\r\n\r\n".utf8)), "a cut stream must not look complete")
        }
    }

    @Test("HTTP/2: a peer whose flow-control window is exhausted has the stream reset after the write timeout, and the connection still answers")
    func stalledReaderHTTP2() async throws {
        let material = try TestTLS()
        defer { material.cleanUp() }
        let failedAt = NIOLockedValueBox<ContinuousClock.Instant?>(nil)
        let firstWriteAt = NIOLockedValueBox<ContinuousClock.Instant?>(nil)
        let chunk = Data(repeating: 0x62, count: 1000)
        try await withServer(tls: material, handler: { request in
            if request.path == "/ok" { return Response(status: .ok, body: Data("ok".utf8)) }
            return .streaming(status: .ok) { writer in
                do {
                    try await writer.write(chunk)                 // more than the 100-octet window: it waits for credit that never comes
                    firstWriteAt.withLockedValue { $0 = .now }
                    try await writer.write(chunk)
                } catch { failedAt.withLockedValue { $0 = .now } }
            }
        }) { running, group in
            // The client advertises a 100-octet initial window (SETTINGS_INITIAL_WINDOW_SIZE = 0x4) and never sends WINDOW_UPDATE.
            let connection = try await RawH2.connect(
                to: running.address, group: group, tls: try material.clientContext(applicationProtocols: ["h2"]),
                settings: [(0x4, 100)])
            #expect(try await connection.wait { $0.contains { $0.type == H2Wire.FrameType.settings.rawValue && !$0.isSettingsAck } })
            try await connection.send(H2Wire.settingsAck)
            let began = ContinuousClock.now
            try await connection.send(H2Wire.headers(stream: 1, endStream: true))
            let reset = try await connection.wait(timeout: .seconds(5)) { frames in
                frames.contains { $0.type == H2Wire.FrameType.rstStream.rawValue && $0.stream == 1 }
            }
            let elapsed = ContinuousClock.now - began
            #expect(reset, "the stalled stream was never reset; frames: \(connection.frames.map(\.type))")
            recordMeasurement("HTTP/2 stalled stream reset after", "\(elapsed.seconds) s (code \(connection.frames.first { $0.type == 3 }?.errorCode.map(String.init) ?? "none"))")
            // TIMING: a timeout test; the elapsed time before the reset is the quantity under test.
            #expect(elapsed >= Self.limit - .milliseconds(5))
            // TIMING: the documented limit plus a second of scheduling slack.
            #expect(elapsed <= Self.limit + Self.slack)
            _ = try #require(failedAt.withLockedValue { $0 }, "the producer was never told the write failed")
            // The connection is still good: GET /ok on stream 3 is answered. HPACK (RFC 7541): 0x82 :method GET, 0x87 :scheme https,
            // 0x04 literal without indexing with name index 4 (:path), 3 octets "/ok", 0x01 name index 1 (:authority), 9 octets.
            let block: [UInt8] = [0x82, 0x87, 0x04, 0x03] + Array("/ok".utf8) + [0x01, 0x09] + Array("localhost".utf8)
            try await connection.send(H2Wire.headers(stream: 3, block: block, endStream: true))
            #expect(try await connection.wait { $0.contains { $0.type == H2Wire.FrameType.data.rawValue && $0.stream == 3 } || $0.contains { $0.type == H2Wire.FrameType.headers.rawValue && $0.stream == 3 } })
            await connection.close()
        }
    }
}
