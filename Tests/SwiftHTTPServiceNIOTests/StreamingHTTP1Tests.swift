import Foundation
import HTTPTypes
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOPosix
import SwiftHTTPService
import Testing
@testable import SwiftHTTPServiceNIO

/// The body of a chunked response (RFC 9112 section 7.1), read from the bytes after the head.
struct ChunkedBody: Equatable {
    var chunks: [Data] = []
    var complete = false

    init(_ data: Data) {
        var rest = data[...]
        while let lineEnd = rest.range(of: Data("\r\n".utf8)) {
            let sizeText = String(decoding: rest[rest.startIndex..<lineEnd.lowerBound], as: UTF8.self)
            guard let size = Int(sizeText, radix: 16) else { return }
            let bodyStart = lineEnd.upperBound
            if size == 0 {
                complete = rest[bodyStart...].starts(with: Data("\r\n".utf8))
                return
            }
            guard rest.distance(from: bodyStart, to: rest.endIndex) >= size + 2 else { return }
            let bodyEnd = rest.index(bodyStart, offsetBy: size)
            chunks.append(Data(rest[bodyStart..<bodyEnd]))
            rest = rest[rest.index(bodyEnd, offsetBy: 2)...]
        }
    }
}

extension RawClient {
    /// The head, as text, and the bytes after it, once the head has arrived.
    var splitResponse: (head: String, body: Data)? {
        let bytes = received
        guard let end = bytes.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        return (String(decoding: bytes[bytes.startIndex..<end.lowerBound], as: UTF8.self), Data(bytes[end.upperBound...]))
    }

    /// Waits until `condition` holds of what has arrived, or the timeout.
    func wait(timeout: Duration = .seconds(5), until condition: (RawClient) -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition(self) { return true }
            try await Task.sleep(for: .milliseconds(5))
        }
        return condition(self)
    }
}

/// The state of one stream, without a connection around it.
@Suite("Stream session")
struct StreamSessionTests {
    @Test("The first reason a stream ended for is the one that stays, and only the call that ended it is told so")
    func firstReasonStays() {
        let channel = EmbeddedChannel()
        let session = StreamSession(channel: channel, limits: Limits()) { _ in channel.eventLoop.makeSucceededVoidFuture() }
        #expect(session.reason == nil)
        #expect(session.end(.durationLimit) == true)
        #expect(session.end(.closed) == false)
        #expect(session.end(.byteLimit) == false)
        #expect(session.reason == .durationLimit)
    }

    @Test("A write is refused with the reason once the stream has ended, and sends nothing")
    func writesAfterTheEnd() async throws {
        let channel = EmbeddedChannel()
        let sent = NIOLockedValueBox(0)
        let session = StreamSession(channel: channel, limits: Limits()) { _ in
            sent.withLockedValue { $0 += 1 }
            return channel.eventLoop.makeSucceededVoidFuture()
        }
        try await session.write(Data("ok".utf8))
        session.end(.writeTimeout)
        await #expect(throws: StreamError.writeTimeout) { try await session.write(Data("late".utf8)) }
        #expect(sent.withLockedValue { $0 } == 1)
    }
}

/// Streaming responses over HTTP/1.1: chunks go out as they are written, the stream is bounded, and every way it
/// can end leaves the connection in a state the client can tell from success.
@Suite("Streaming over HTTP/1.1", .serialized)
struct StreamingHTTP1Tests {

    private func start(
        limits: Limits = Limits(), handler: @escaping Handler
    ) async throws -> (HTTPServer, BoundAddress) {
        let server = HTTPServer(configuration: try ServiceConfiguration(port: 0, limits: limits), handler: handler)
        return (server, try await server.start())
    }

    private let get = "GET /x HTTP/1.1\r\nHost: h\r\n\r\n"

    // MARK: Chunks go out as they are written

    @Test("A chunk reaches the client before the producer has finished, and the body is the chunks in order, ended by the terminator")
    func incremental() async throws {
        let gate = HoldGate()
        let (server, address) = try await start { _ in
            .streaming(status: .ok) { writer in
                try await writer.write(Data("first".utf8))
                await gate.wait()
                try await writer.write(Data("second".utf8))
            }
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        try await client.send(get)
        // The first chunk is on the wire while the producer is still waiting on the gate.
        #expect(try await client.wait { ChunkedBody($0.splitResponse?.body ?? Data()).chunks == [Data("first".utf8)] })
        #expect(ChunkedBody(client.splitResponse?.body ?? Data()).complete == false)
        await gate.release()
        #expect(try await client.wait { ChunkedBody($0.splitResponse?.body ?? Data()).complete })
        let split = try #require(client.splitResponse)
        #expect(ChunkedBody(split.body).chunks == [Data("first".utf8), Data("second".utf8)])
        let head = split.head.lowercased()
        #expect(head.hasPrefix("http/1.1 200"))
        #expect(head.contains("transfer-encoding: chunked"))
        #expect(!head.contains("content-length"))
        #expect(head.contains("connection: keep-alive"))
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("The handler's own Content-Length, Transfer-Encoding and Connection are the transport's to set, and are not sent")
    func transportOwnsFraming() async throws {
        let (server, address) = try await start { _ in
            var headers = HTTPFields()
            headers[.contentLength] = "999"
            headers[.connection] = "upgrade"
            if let name = HTTPField.Name("Transfer-Encoding") { headers[name] = "identity" }
            headers[.contentType] = "text/plain"
            return .streaming(status: .ok, headers: headers) { writer in try await writer.write(Data("x".utf8)) }
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        try await client.send(get)
        #expect(try await client.wait { ChunkedBody($0.splitResponse?.body ?? Data()).complete })
        let head = try #require(client.splitResponse).head.lowercased()
        #expect(!head.contains("content-length: 999"))
        #expect(!head.contains("upgrade"))
        #expect(!head.contains("identity"))
        #expect(head.contains("content-type: text/plain"))
        #expect(head.contains("transfer-encoding: chunked"))
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("A connection that carried a stream serves the next request on it")
    func keepAliveAfterAStream() async throws {
        let (server, address) = try await start { request in
            if request.path == "/stream" { return .streaming(status: .ok) { writer in try await writer.write(Data("s".utf8)) } }
            return Response(status: .ok, body: Data("plain".utf8))
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        try await client.send("GET /stream HTTP/1.1\r\nHost: h\r\n\r\n")
        #expect(try await client.wait { ChunkedBody($0.splitResponse?.body ?? Data()).complete })
        let before = client.received.count
        try await client.send("GET /plain HTTP/1.1\r\nHost: h\r\n\r\n")
        #expect(try await client.wait { String(decoding: $0.received.dropFirst(before), as: UTF8.self).hasSuffix("plain") })
        #expect(!client.isClosed)
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("A large stream to a reading client arrives whole and in order")
    func large() async throws {
        let chunk = Data((0..<65_536).map { UInt8($0 & 0xFF) })
        let (server, address) = try await start { _ in
            .streaming(status: .ok) { writer in for _ in 0..<80 { try await writer.write(chunk) } }       // 5 MiB
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        try await client.send(get)
        #expect(try await client.wait(timeout: .seconds(20)) { ChunkedBody($0.splitResponse?.body ?? Data()).complete })
        let body = ChunkedBody(try #require(client.splitResponse).body)
        #expect(body.chunks.count == 80)
        #expect(body.chunks.allSatisfy { $0 == chunk })
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("A writer kept past the end of its stream refuses further writes with closed, and sends nothing")
    func lateWrites() async throws {
        let kept = NIOLockedValueBox<ResponseWriter?>(nil)
        let (server, address) = try await start { _ in
            .streaming(status: .ok) { writer in
                kept.withLockedValue { $0 = writer }
                try await writer.write(Data("x".utf8))
            }
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        try await client.send(get)
        #expect(try await client.wait { ChunkedBody($0.splitResponse?.body ?? Data()).complete })
        let before = client.received.count
        let writer = try #require(kept.withLockedValue { $0 })
        await #expect(throws: StreamError.closed) { try await writer.write(Data("late".utf8)) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(client.received.count == before)               // nothing went out after the terminator
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    // MARK: Requests that cannot carry a chunked body

    @Test("A HEAD gets the head and nothing more, the producer is never run, and the connection closes")
    func head() async throws {
        let ran = NIOLockedValueBox(false)
        let (server, address) = try await start { _ in
            .streaming(status: .ok) { _ in ran.withLockedValue { $0 = true } }
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        try await client.send("HEAD /x HTTP/1.1\r\nHost: h\r\n\r\n")
        #expect(try await client.waitUntilClosed())
        let split = try #require(client.splitResponse)
        #expect(split.head.lowercased().contains("connection: close"))
        #expect(!split.head.lowercased().contains("content-length"))
        #expect(!split.head.lowercased().contains("transfer-encoding"))
        #expect(split.body.isEmpty)
        #expect(ran.withLockedValue { $0 } == false)
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("To an HTTP/1.0 client, which cannot read chunks, the body is sent unframed and the connection closes at its end")
    func http10() async throws {
        let (server, address) = try await start { _ in
            .streaming(status: .ok) { writer in
                try await writer.write(Data("ab".utf8))
                try await writer.write(Data("cd".utf8))
            }
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        try await client.send("GET /x HTTP/1.0\r\n\r\n")
        #expect(try await client.waitUntilClosed())
        let split = try #require(client.splitResponse)
        #expect(!split.head.lowercased().contains("transfer-encoding"))
        #expect(split.head.lowercased().contains("connection: close"))
        #expect(split.body == Data("abcd".utf8))
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("A status that forbids a body (204, 304) is sent as an ordinary bodyless response, and the producer is not run")
    func noBodyStatuses() async throws {
        for code in [204, 304] {
            let ran = NIOLockedValueBox(false)
            let (server, address) = try await start { _ in
                .streaming(status: HTTPResponse.Status(code: code)) { _ in ran.withLockedValue { $0 = true } }
            }
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let client = try await RawClient.connect(to: address, group: group)
            try await client.send(get)
            #expect(try await client.wait { $0.splitResponse?.head.hasPrefix("HTTP/1.1 \(code)") == true })
            let split = try #require(client.splitResponse)
            #expect(split.head.hasPrefix("HTTP/1.1 \(code)"))
            #expect(!split.head.lowercased().contains("transfer-encoding"))
            #expect(!client.isClosed)
            #expect(ran.withLockedValue { $0 } == false)
            await client.close()
            try await group.shutdownGracefully()
            await server.shutdown()
        }
    }

    @Test("A streaming response with a status that is not a final one is the transport's 500, like any other")
    func informationalStatus() async throws {
        let (server, address) = try await start { _ in .streaming(status: HTTPResponse.Status(code: 100)) { _ in } }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        try await client.send(get)
        #expect(try await client.response()?.status == 500)
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    // MARK: How a stream ends

    @Test("A producer that throws ends the response abruptly: the chunks sent stay sent, there is no terminator, and the connection closes")
    func producerThrows() async throws {
        struct Boom: Error {}
        let (server, address) = try await start { _ in
            .streaming(status: .ok) { writer in
                try await writer.write(Data("before".utf8))
                throw Boom()
            }
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        try await client.send(get)
        #expect(try await client.waitUntilClosed())
        let body = ChunkedBody(try #require(client.splitResponse).body)
        #expect(body.chunks == [Data("before".utf8)])
        #expect(body.complete == false)                       // truncated, and the client can tell
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("When the peer goes away the producer's next write throws and the producer is cancelled")
    func peerLeaves() async throws {
        let outcome = NIOLockedValueBox<String?>(nil)
        let started = HoldGate()
        let (server, address) = try await start { _ in
            .streaming(status: .ok) { writer in
                try await writer.write(Data("hello".utf8))
                await started.release()
                do {
                    while !Task.isCancelled {                                 // ends by a failed write or by cancellation
                        try await writer.write(Data("more".utf8))
                        try await Task.sleep(for: .milliseconds(10))
                    }
                } catch {
                    outcome.withLockedValue { $0 = (error is CancellationError) ? "cancelled" : "\(error)" }
                }
            }
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        try await client.send(get)
        await started.wait()
        await client.close()
        let deadline = ContinuousClock.now + .seconds(5)
        while outcome.withLockedValue({ $0 }) == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let ended = try #require(outcome.withLockedValue { $0 })
        #expect(ended == "cancelled" || ended == StreamError.closed.description || ended == "closed", "ended with \(ended)")
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("A stream that writes past the byte limit has that write refused with byteLimit, and the connection closes with nothing more sent")
    func byteLimit() async throws {
        var limits = Limits()
        limits.maximumStreamBytes = 10
        let error = NIOLockedValueBox<StreamError?>(nil)
        let (server, address) = try await start(limits: limits) { _ in
            .streaming(status: .ok) { writer in
                try await writer.write(Data("123456".utf8))                      // 6 of 10
                do { try await writer.write(Data("abcdef".utf8)) }                // 12 of 10: refused
                catch let streamError as StreamError { error.withLockedValue { $0 = streamError }; throw streamError }
            }
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        try await client.send(get)
        #expect(try await client.waitUntilClosed())
        let body = ChunkedBody(try #require(client.splitResponse).body)
        #expect(body.chunks == [Data("123456".utf8)])
        #expect(body.complete == false)
        #expect(error.withLockedValue { $0 } == .byteLimit)
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("A stream at exactly the byte limit completes")
    func atTheByteLimit() async throws {
        var limits = Limits()
        limits.maximumStreamBytes = 10
        let (server, address) = try await start(limits: limits) { _ in
            .streaming(status: .ok) { writer in
                try await writer.write(Data("12345".utf8))
                try await writer.write(Data("67890".utf8))
            }
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        try await client.send(get)
        #expect(try await client.wait { ChunkedBody($0.splitResponse?.body ?? Data()).complete })
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("A stream that runs past its duration is cut off at the limit even if the producer is idle, and the producer is cancelled")
    func durationLimit() async throws {
        var limits = Limits()
        limits.maximumStreamDuration = .milliseconds(300)
        let cancelled = NIOLockedValueBox(false)
        let (server, address) = try await start(limits: limits) { _ in
            .streaming(status: .ok) { writer in
                try await writer.write(Data("start".utf8))
                do { try await Task.sleep(for: .seconds(30)) } catch { cancelled.withLockedValue { $0 = true } }
            }
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        let began = ContinuousClock.now
        try await client.send(get)
        #expect(try await client.waitUntilClosed(timeout: .seconds(5)))
        #expect(ContinuousClock.now - began < .seconds(3))
        #expect(ChunkedBody(try #require(client.splitResponse).body).complete == false)
        let deadline = ContinuousClock.now + .seconds(3)
        while !cancelled.withLockedValue({ $0 }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(cancelled.withLockedValue { $0 })
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("A producer that ignores the error from a limit and hangs is cut off all the same: the connection closes without its help")
    func hungProducerIsCutOff() async throws {
        var limits = Limits()
        limits.maximumStreamBytes = 4
        let hang = HoldGate()
        let (server, address) = try await start(limits: limits) { _ in
            .streaming(status: .ok) { writer in
                try? await writer.write(Data("toolong".utf8))            // refused: over the byte limit
                await hang.wait()                                         // and the producer carries on, deaf to everything
            }
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        try await client.send(get)
        #expect(try await client.waitUntilClosed(timeout: .seconds(3)))
        await hang.release()
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("A stream past its duration is cut off even if its producer never looks at cancellation, and the producer's next write says durationLimit")
    func durationCutsOffADeafProducer() async throws {
        var limits = Limits()
        limits.maximumStreamDuration = .milliseconds(300)
        let hang = HoldGate()
        let seen = NIOLockedValueBox<StreamError?>(nil)
        let (server, address) = try await start(limits: limits) { _ in
            .streaming(status: .ok) { writer in
                try await writer.write(Data("start".utf8))
                await hang.wait()                                         // deaf: not cancelled by closing the connection
                do { try await writer.write(Data("after".utf8)) } catch let failure as StreamError { seen.withLockedValue { $0 = failure } }
            }
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        try await client.send(get)
        #expect(try await client.waitUntilClosed(timeout: .seconds(3)))
        await hang.release()
        let deadline = ContinuousClock.now + .seconds(3)
        while seen.withLockedValue({ $0 }) == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(seen.withLockedValue { $0 } == .durationLimit)
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("A peer that stops reading cannot hold a stream: the write that cannot finish times out, the producer is told, the connection closes")
    func writeTimeout() async throws {
        var limits = Limits()
        limits.streamWriteTimeout = .milliseconds(400)
        let ended = NIOLockedValueBox<String?>(nil)
        let big = Data(repeating: 0x61, count: 1 << 20)
        let (server, address) = try await start(limits: limits) { _ in
            .streaming(status: .ok) { writer in
                do { for _ in 0..<512 { try await writer.write(big) } }              // up to 512 MiB: far more than any socket buffer holds
                catch let failure { ended.withLockedValue { $0 = (failure as? StreamError)?.description ?? "\(failure)" } }
            }
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        try await client.channel.setOption(ChannelOptions.autoRead, value: false).get()           // the client does not read
        try await client.send(get)
        let deadline = ContinuousClock.now + .seconds(15)
        while ended.withLockedValue({ $0 }) == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(ended.withLockedValue { $0 } == StreamError.writeTimeout.description, "ended with \(String(describing: ended.withLockedValue { $0 }))")
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("A shutdown cuts a stream off when the grace period ends, cancels the producer, and still completes")
    func shutdownCutsOff() async throws {
        var limits = Limits()
        limits.shutdownGrace = .milliseconds(300)
        let cancelled = NIOLockedValueBox(false)
        let started = HoldGate()
        let (server, address) = try await start(limits: limits) { _ in
            .streaming(status: .ok) { writer in
                try await writer.write(Data("start".utf8))
                await started.release()
                do { try await Task.sleep(for: .seconds(30)) } catch { cancelled.withLockedValue { $0 = true } }
            }
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        try await client.send(get)
        await started.wait()
        let began = ContinuousClock.now
        await server.shutdown()
        #expect(ContinuousClock.now - began < .seconds(5))
        #expect(try await client.waitUntilClosed())
        let deadline = ContinuousClock.now + .seconds(3)
        while !cancelled.withLockedValue({ $0 }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(cancelled.withLockedValue { $0 })
        await client.close()
        try await group.shutdownGracefully()
    }

    @Test("A stream that finishes before a shutdown's grace ends is finished properly, and the connection then closes")
    func shutdownWaitsForAShortStream() async throws {
        let gate = HoldGate()
        let started = HoldGate()
        let (server, address) = try await start { _ in
            .streaming(status: .ok) { writer in
                try await writer.write(Data("one".utf8))
                await started.release()
                await gate.wait()
                try await writer.write(Data("two".utf8))
            }
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        try await client.send(get)
        await started.wait()
        let shutdown = Task { await server.shutdown() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!client.isClosed)                              // still streaming: shutdown waits
        await gate.release()
        #expect(try await client.waitUntilClosed())
        let body = ChunkedBody(try #require(client.splitResponse).body)
        #expect(body.chunks == [Data("one".utf8), Data("two".utf8)])
        #expect(body.complete)
        await shutdown.value
        await client.close()
        try await group.shutdownGracefully()
    }
}
