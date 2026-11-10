import Foundation
import HTTPTypes
import NIOConcurrencyHelpers
import NIOPosix
import SwiftHTTPService
import Testing
@testable import SwiftHTTPServiceNIO

/// Streaming responses over HTTP/2: the body goes out in DATA frames as it is written, flow control paces the
/// producer, and a stream that fails is reset without disturbing the connection or its other streams.
@Suite("Streaming over HTTP/2", .serialized)
struct StreamingHTTP2Tests {

    private func withServer<T>(
        limits: Limits = Limits(), handler: @escaping Handler,
        _ body: (HTTPServer, BoundAddress, TestTLS, MultiThreadedEventLoopGroup) async throws -> T
    ) async throws -> T {
        let material = try TestTLS()
        defer { material.cleanUp() }
        let server = HTTPServer(configuration: try ServiceConfiguration(port: 0, tls: material.files, limits: limits), handler: handler)
        let address = try await server.start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let result: T
        do { result = try await body(server, address, material, group) } catch {
            try? await group.shutdownGracefully()
            await server.shutdown()
            throw error
        }
        try await group.shutdownGracefully()
        await server.shutdown()
        return result
    }

    private func connect(_ address: BoundAddress, _ material: TestTLS, _ group: MultiThreadedEventLoopGroup) async throws -> H2Client {
        try await H2Client.connect(to: address, group: group, tls: try material.clientContext(applicationProtocols: ["h2"]))
    }

    @Test("A DATA frame reaches the client before the producer has finished; the body is the writes in order, ended by END_STREAM")
    func incremental() async throws {
        let gate = HoldGate()
        try await withServer(handler: { _ in
            .streaming(status: .ok) { writer in
                try await writer.write(Data("first".utf8))
                await gate.wait()
                try await writer.write(Data("second".utf8))
            }
        }) { _, address, material, group in
            let client = try await connect(address, material, group)
            let stream = try await client.open("GET", "/x")
            #expect(try await stream.wait { $0.text == "first" })
            #expect(stream.response.ended == false)
            await gate.release()
            #expect(try await stream.wait { $0.ended })
            #expect(stream.response.text == "firstsecond")
            #expect(stream.response.status == 200)
            #expect(stream.response.header("content-length") == nil)
            #expect(stream.response.header("connection") == nil)
            let date = try #require(stream.response.header("date"))
            _ = try #require(date.range(of: #"^[A-Z][a-z]{2}, \d{2} [A-Z][a-z]{2} \d{4} \d{2}:\d{2}:\d{2} GMT$"#, options: .regularExpression))
            await client.close()
        }
    }

    @Test("A large stream, bigger than the flow-control window, arrives whole and in order to a client that reads")
    func large() async throws {
        let chunk = Data((0..<65_536).map { UInt8($0 & 0xFF) })
        try await withServer(handler: { _ in
            .streaming(status: .ok) { writer in for _ in 0..<80 { try await writer.write(chunk) } }       // 5 MiB
        }) { _, address, material, group in
            let client = try await connect(address, material, group)
            let stream = try await client.open("GET", "/x")
            #expect(try await stream.wait(timeout: .seconds(30)) { $0.ended })
            #expect(stream.response.body.count == 80 * 65_536)
            #expect(stream.response.body == Data(Array(repeating: chunk, count: 80).joined()))
            await client.close()
        }
    }

    @Test("A HEAD gets the headers and END_STREAM, with no body, and the producer is never run")
    func head() async throws {
        let ran = NIOLockedValueBox(false)
        try await withServer(handler: { _ in
            .streaming(status: .ok) { _ in ran.withLockedValue { $0 = true } }
        }) { _, address, material, group in
            let client = try await connect(address, material, group)
            let response = try await client.request("HEAD", "/x")
            #expect(response.status == 200)
            #expect(response.body.isEmpty)
            #expect(response.ended)
            #expect(ran.withLockedValue { $0 } == false)
            await client.close()
        }
    }

    @Test("A status that forbids a body (204, 304) is an ordinary bodyless response, and the producer is not run")
    func noBodyStatuses() async throws {
        for code in [204, 304] {
            let ran = NIOLockedValueBox(false)
            try await withServer(handler: { _ in
                .streaming(status: HTTPResponse.Status(code: code)) { _ in ran.withLockedValue { $0 = true } }
            }) { _, address, material, group in
                let client = try await connect(address, material, group)
                let response = try await client.request("GET", "/x")
                #expect(response.status == code)
                #expect(response.body.isEmpty)
                #expect(response.ended)
                #expect(ran.withLockedValue { $0 } == false)
                await client.close()
            }
        }
    }

    @Test("A producer that throws resets its stream with INTERNAL_ERROR after the data already sent, and the connection serves the next request")
    func producerThrows() async throws {
        struct Boom: Error {}
        try await withServer(handler: { request in
            if request.path == "/boom" {
                return .streaming(status: .ok) { writer in
                    try await writer.write(Data("before".utf8))
                    throw Boom()
                }
            }
            return Response(status: .ok, body: Data("fine".utf8))
        }) { _, address, material, group in
            let client = try await connect(address, material, group)
            let stream = try await client.open("GET", "/boom")
            #expect(try await stream.wait { $0.resetCode != nil })   // the reset is a frame of its own, behind any answer
            #expect(stream.response.resetCode == 2)               // INTERNAL_ERROR, RFC 9113 section 7
            #expect(stream.response.ended == false)
            #expect(stream.response.text == "before")
            #expect(try await client.request("GET", "/ok").text == "fine")       // the connection is untouched
            #expect(client.channel.isActive)
            await client.close()
        }
    }

    @Test("When the client resets a stream the producer's next write throws and the producer is cancelled; other streams go on")
    func peerResets() async throws {
        let outcome = NIOLockedValueBox<String?>(nil)
        let started = HoldGate()
        try await withServer(handler: { request in
            if request.path == "/long" {
                return .streaming(status: .ok) { writer in
                    try await writer.write(Data("hello".utf8))
                    await started.release()
                    do {
                        while !Task.isCancelled {
                            try await writer.write(Data("more".utf8))
                            try await Task.sleep(for: .milliseconds(10))
                        }
                    } catch let failure {
                        outcome.withLockedValue { $0 = (failure is CancellationError) ? "cancelled" : "\(failure)" }
                    }
                }
            }
            return Response(status: .ok, body: Data("other".utf8))
        }) { _, address, material, group in
            let client = try await connect(address, material, group)
            let stream = try await client.open("GET", "/long")
            await started.wait()
            await stream.reset()
            let deadline = ContinuousClock.now + .seconds(5)
            while outcome.withLockedValue({ $0 }) == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            let ended = try #require(outcome.withLockedValue { $0 })
            #expect(ended == "cancelled" || ended == StreamError.closed.description, "ended with \(ended)")
            #expect(try await client.request("GET", "/other").text == "other")
            await client.close()
        }
    }

    @Test("Past the byte limit the write is refused with byteLimit and the stream is reset; at the limit it completes")
    func byteLimit() async throws {
        var limits = Limits()
        limits.maximumStreamBytes = 10
        let error = NIOLockedValueBox<StreamError?>(nil)
        try await withServer(limits: limits, handler: { request in
            .streaming(status: .ok) { writer in
                try await writer.write(Data("12345".utf8))
                if request.path == "/over" {
                    do { try await writer.write(Data("678901".utf8)) }                // 11 of 10
                    catch let failure as StreamError { error.withLockedValue { $0 = failure }; throw failure }
                } else {
                    try await writer.write(Data("67890".utf8))                         // exactly 10
                }
            }
        }) { _, address, material, group in
            let client = try await connect(address, material, group)
            let over = try await client.open("GET", "/over")
            #expect(try await over.wait { $0.resetCode != nil })
            #expect(over.response.resetCode == 8)                  // CANCEL: the server ended it deliberately
            #expect(over.response.ended == false)
            #expect(over.response.body.count <= 10)
            #expect(error.withLockedValue { $0 } == .byteLimit)
            let exact = try await client.open("GET", "/exact")
            #expect(try await exact.wait { $0.ended })
            #expect(exact.response.text == "1234567890")
            await client.close()
        }
    }

    @Test("A stream past its duration is reset at the limit even if the producer is idle, and the producer is cancelled")
    func durationLimit() async throws {
        var limits = Limits()
        limits.maximumStreamDuration = .milliseconds(300)
        let cancelled = NIOLockedValueBox(false)
        try await withServer(limits: limits, handler: { _ in
            .streaming(status: .ok) { writer in
                try await writer.write(Data("start".utf8))
                do { try await Task.sleep(for: .seconds(30)) } catch { cancelled.withLockedValue { $0 = true } }
            }
        }) { _, address, material, group in
            let client = try await connect(address, material, group)
            let began = ContinuousClock.now
            let stream = try await client.open("GET", "/x")
            #expect(try await stream.wait(timeout: .seconds(5)) { $0.resetCode == 8 || $0.ended })
            #expect(ContinuousClock.now - began < .seconds(3))
            #expect(stream.response.ended == false)
            let deadline = ContinuousClock.now + .seconds(3)
            while !cancelled.withLockedValue({ $0 }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(cancelled.withLockedValue { $0 })
            #expect(client.channel.isActive)                                      // only the stream was ended
            await client.close()
        }
    }

    @Test("A stream past its duration is reset even if its producer never looks at cancellation, and one past the byte limit with a hung producer too")
    func deafProducersAreCutOff() async throws {
        var limits = Limits()
        limits.maximumStreamDuration = .milliseconds(300)
        limits.maximumStreamBytes = 4
        let hang = HoldGate()
        try await withServer(limits: limits, handler: { request in
            .streaming(status: .ok) { writer in
                if request.path == "/bytes" { try? await writer.write(Data("toolong".utf8)) } else { try await writer.write(Data("ok".utf8)) }
                await hang.wait()
            }
        }) { _, address, material, group in
            let client = try await connect(address, material, group)
            let duration = try await client.open("GET", "/duration")
            #expect(try await duration.wait(timeout: .seconds(3)) { $0.resetCode == 8 })
            let bytes = try await client.open("GET", "/bytes")
            #expect(try await bytes.wait(timeout: .seconds(3)) { $0.resetCode == 8 })
            #expect(client.channel.isActive)
            await hang.release()
            await client.close()
        }
    }

    @Test("The producer of a stream cut off at its duration is told durationLimit by its next write")
    func durationReason() async throws {
        var limits = Limits()
        limits.maximumStreamDuration = .milliseconds(300)
        let hang = HoldGate()
        let seen = NIOLockedValueBox<StreamError?>(nil)
        try await withServer(limits: limits, handler: { _ in
            .streaming(status: .ok) { writer in
                try await writer.write(Data("start".utf8))
                await hang.wait()
                do { try await writer.write(Data("after".utf8)) } catch let failure as StreamError { seen.withLockedValue { $0 = failure } }
            }
        }) { _, address, material, group in
            let client = try await connect(address, material, group)
            let stream = try await client.open("GET", "/x")
            #expect(try await stream.wait(timeout: .seconds(3)) { $0.resetCode == 8 })
            await hang.release()
            let deadline = ContinuousClock.now + .seconds(3)
            while seen.withLockedValue({ $0 }) == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(seen.withLockedValue { $0 } == .durationLimit)
            await client.close()
        }
    }

    @Test("A client that does not read holds back its stream by flow control, and the write that cannot finish times out")
    func writeTimeout() async throws {
        var limits = Limits()
        limits.streamWriteTimeout = .milliseconds(400)
        let ended = NIOLockedValueBox<String?>(nil)
        let big = Data(repeating: 0x61, count: 1 << 20)
        try await withServer(limits: limits, handler: { _ in
            .streaming(status: .ok) { writer in
                do { for _ in 0..<64 { try await writer.write(big) } }
                catch let failure { ended.withLockedValue { $0 = (failure as? StreamError)?.description ?? "\(failure)" } }
            }
        }) { _, address, material, group in
            let client = try await connect(address, material, group)
            _ = try await client.open("GET", "/x", paused: true)                   // never reads, so never gives the window back
            let deadline = ContinuousClock.now + .seconds(15)
            while ended.withLockedValue({ $0 }) == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(ended.withLockedValue { $0 } == StreamError.writeTimeout.description, "ended with \(String(describing: ended.withLockedValue { $0 }))")
            await client.close()
        }
    }

    @Test("Streams on one connection are independent: a stalled one does not stop another")
    func independent() async throws {
        let gate = HoldGate()
        try await withServer(handler: { request in
            if request.path == "/slow" {
                return .streaming(status: .ok) { writer in
                    try await writer.write(Data("slow-1".utf8))
                    await gate.wait()
                    try await writer.write(Data("slow-2".utf8))
                }
            }
            return .streaming(status: .ok) { writer in try await writer.write(Data("quick".utf8)) }
        }) { _, address, material, group in
            let client = try await connect(address, material, group)
            let slow = try await client.open("GET", "/slow")
            #expect(try await slow.wait { $0.text == "slow-1" })
            let quick = try await client.open("GET", "/quick")
            #expect(try await quick.wait { $0.ended })
            #expect(quick.response.text == "quick")
            #expect(slow.response.ended == false)
            await gate.release()
            #expect(try await slow.wait { $0.ended })
            #expect(slow.response.text == "slow-1slow-2")
            await client.close()
        }
    }

    @Test("A shutdown cuts a stream off at the end of the grace period, cancels the producer, and still completes")
    func shutdownCutsOff() async throws {
        var limits = Limits()
        limits.shutdownGrace = .milliseconds(300)
        let cancelled = NIOLockedValueBox(false)
        let started = HoldGate()
        let material = try TestTLS()
        defer { material.cleanUp() }
        let server = HTTPServer(configuration: try ServiceConfiguration(port: 0, tls: material.files, limits: limits), handler: { _ in
            .streaming(status: .ok) { writer in
                try await writer.write(Data("start".utf8))
                await started.release()
                do { try await Task.sleep(for: .seconds(30)) } catch { cancelled.withLockedValue { $0 = true } }
            }
        })
        let address = try await server.start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await connect(address, material, group)
        _ = try await client.open("GET", "/x")
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
}
