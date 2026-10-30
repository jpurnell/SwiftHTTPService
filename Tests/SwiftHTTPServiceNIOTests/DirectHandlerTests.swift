import Foundation
import HTTPTypes
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOExtras
import NIOHTTP1
import Testing
import SwiftHTTPService
@testable import SwiftHTTPServiceNIO

/// The connection handler on its own, fed already-parsed request parts with no HTTP parser in front.
///
/// NIO's parser refuses much of what the handler also refuses (a `Content-Length` with a
/// `Transfer-Encoding`, a duplicate `Content-Length`). The full-pipeline tests therefore cannot tell whether
/// the handler's own rule is there, and if NIO relaxed its parser the handler would be the only guard left.
/// These tests are the handler's own proof.
@Suite("Connection handler, without the parser")
struct DirectHandlerTests {

    private func harness(
        limits: Limits = Limits(), refusals: RefusalHooks = RefusalHooks(), handler: @escaping Handler = ok()
    ) async throws -> (NIOAsyncTestingChannel, Recorder) {
        let recorder = Recorder()
        let context = ServerContext(
            configuration: try ServiceConfiguration(port: 0, limits: limits),
            handler: { request in
                await recorder.record(request)
                return try await handler(request)
            },
            refusals: refusals)
        let channel = NIOAsyncTestingChannel()
        try await channel.eventLoop.submit {
            let operations = channel.pipeline.syncOperations
            try operations.addHandler(HTTPResponseEncoder())
            try operations.addHandler(ConnectionHandler(server: context))
        }.get()
        try await channel.connect(to: SocketAddress(ipAddress: "192.0.2.9", port: 1))
        return (channel, recorder)
    }

    @Test("A refusal's record shows the request line safely even when the parser, which would stop it, is not there to")
    func recordsAreEscapedWithoutTheParser() async throws {
        let seen = NIOLockedValueBox<[RefusalRecord]>([])
        let hooks = RefusalHooks(record: { record in seen.withLockedValue { $0.append(record) } })
        // An unsafe target: a line break, a header-looking line, DEL and a non-ASCII character.
        let (channel, _) = try await harness(refusals: hooks)
        try await channel.writeInbound(head([("Host", "h")], method: .GET, uri: "//x\r\nInjected: 1\u{7F}\u{E9}"))
        try await channel.writeInbound(HTTPServerRequestPart.end(nil))
        _ = try await status(of: channel)
        let record = try #require(seen.withLockedValue { $0 }.first)
        #expect(record.kind == .malformedTarget)
        #expect(record.target == "//x%0D%0AInjected:%201%7F%C3%A9")
        #expect(record.method == "GET")
        #expect(record.peerAddress == "192.0.2.9")
        // An unsafe method is not shown at all.
        let (other, _) = try await harness(refusals: hooks)
        try await other.writeInbound(head([("Host", "h")], method: .RAW(value: "G\r\nET"), uri: "/x"))
        try await other.writeInbound(HTTPServerRequestPart.end(nil))
        _ = try await status(of: other)
        let second = try #require(seen.withLockedValue { $0 }.last)
        #expect(seen.withLockedValue { $0.count } == 2)
        #expect(second.kind == .badRequest)
        #expect(second.method == nil)
        #expect(second.target == "/x")
    }

    private func status(of channel: NIOAsyncTestingChannel) async throws -> Int? {
        let deadline = ContinuousClock.now + .seconds(2)
        var data = Data()
        while ContinuousClock.now < deadline {
            while let buffer = try await channel.readOutbound(as: ByteBuffer.self) {
                data.append(contentsOf: buffer.readableBytesView)
            }
            if let line = String(data: data, encoding: .utf8)?.split(whereSeparator: \.isNewline).first {
                let parts = line.split(separator: " ")
                if parts.count > 1, let code = Int(parts[1]) { return code }
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        return nil
    }

    private func head(
        _ fields: [(String, String)], version: HTTPVersion = .http1_1, method: HTTPMethod = .POST, uri: String = "/a"
    ) -> HTTPServerRequestPart {
        var headers = HTTPHeaders()
        for (name, value) in fields { headers.add(name: name, value: value) }
        return .head(HTTPRequestHead(version: version, method: method, uri: uri, headers: headers))
    }

    private func run(_ parts: [HTTPServerRequestPart]) async throws -> (status: Int?, ran: Bool) {
        let (channel, recorder) = try await harness()
        for part in parts { try await channel.writeInbound(part) }
        let code = try await status(of: channel)
        let ran = await !recorder.requests.isEmpty
        _ = try await channel.finish(acceptAlreadyClosed: true)
        return (code, ran)
    }

    // MARK: Framing

    @Test("Content-Length together with Transfer-Encoding is refused by the handler itself")
    func lengthAndCoding() async throws {
        let result = try await run([head([("Host", "h"), ("Content-Length", "0"), ("Transfer-Encoding", "chunked")]), .end(nil)])
        #expect(result.status == 400)
        #expect(!result.ran)
    }

    @Test("Two Content-Length fields are refused, even with the same value")
    func twoLengths() async throws {
        for second in ["4", "5"] {
            let result = try await run([head([("Host", "h"), ("Content-Length", "4"), ("Content-Length", second)]), .end(nil)])
            #expect(result.status == 400)
            #expect(!result.ran)
        }
    }

    @Test("Two Transfer-Encoding fields are refused")
    func twoCodings() async throws {
        let result = try await run([head([("Host", "h"), ("Transfer-Encoding", "chunked"), ("Transfer-Encoding", "chunked")]), .end(nil)])
        #expect(result.status == 400)
        #expect(!result.ran)
    }

    @Test("Any coding other than exactly chunked is refused", arguments: ["gzip", "gzip, chunked", "chunked, gzip", "identity", "chunked;q=1", ""])
    func otherCodings(_ coding: String) async throws {
        let result = try await run([head([("Host", "h"), ("Transfer-Encoding", coding)]), .end(nil)])
        #expect(result.status == 400)
        #expect(!result.ran)
    }

    @Test("Transfer-Encoding is not allowed on HTTP/1.0")
    func codingOnHTTP10() async throws {
        let result = try await run([head([("Transfer-Encoding", "chunked")], version: .http1_0), .end(nil)])
        #expect(result.status == 400)
    }

    @Test("A Content-Length that is not plain digits is refused", arguments: ["", "-1", "+4", "0x4", "4, 4", "4.0", "abc", "1 2"])
    func badLengths(_ value: String) async throws {
        let result = try await run([head([("Host", "h"), ("Content-Length", value)]), .end(nil)])
        #expect(result.status == 400)
        #expect(!result.ran)
    }

    @Test("A Content-Length too large to be a number is refused, not trapped")
    func hugeLength() async throws {
        let result = try await run([head([("Host", "h"), ("Content-Length", String(repeating: "9", count: 40))]), .end(nil)])
        #expect(result.status == 400)
    }

    // MARK: Host and values

    @Test("HTTP/1.1 needs exactly one Host")
    func hosts() async throws {
        #expect(try await run([head([]), .end(nil)]).status == 400)
        #expect(try await run([head([("Host", "a"), ("Host", "b")]), .end(nil)]).status == 400)
        #expect(try await run([head([("Host", "a")]), .end(nil)]).status == 200)
    }

    @Test("A header value holding CR, LF or NUL is refused", arguments: ["a\rb", "a\nb", "a\u{0}b"])
    func controlCharacters(_ value: String) async throws {
        let result = try await run([head([("Host", "h"), ("X-Thing", value)]), .end(nil)])
        #expect(result.status == 400)
        #expect(!result.ran)
    }

    @Test("A header name that is not a token is refused", arguments: ["X Bad", "X-Bad:", "", "X\u{0}Bad"])
    func badNames(_ name: String) async throws {
        let result = try await run([head([("Host", "h"), (name, "v")]), .end(nil)])
        #expect(result.status == 400)
        #expect(!result.ran)
    }

    // MARK: Expect

    @Test("More than one Expect, or any other than 100-continue, is a 417")
    func expectations() async throws {
        #expect(try await run([head([("Host", "h"), ("Expect", "100-continue"), ("Expect", "100-continue")]), .end(nil)]).status == 417)
        #expect(try await run([head([("Host", "h"), ("Expect", "nope")]), .end(nil)]).status == 417)
        #expect(try await run([head([("Host", "h"), ("Expect", "100-continue")]), .end(nil)]).status == 200)
    }

    // MARK: Behaviour the parser cannot show

    @Test("A body that arrives in chunks and passes the limit by one byte is a 413")
    func chunkedByOne() async throws {
        let (channel, recorder) = try await harness(limits: Limits(maximumBodyBytes: 10))
        try await channel.writeInbound(head([("Host", "h"), ("Transfer-Encoding", "chunked")]))
        try await channel.writeInbound(HTTPServerRequestPart.body(ByteBuffer(string: "123456")))
        try await channel.writeInbound(HTTPServerRequestPart.body(ByteBuffer(string: "78901")))   // 6 + 5 = 11 > 10
        #expect(try await status(of: channel) == 413)
        #expect(await recorder.requests.isEmpty)
        _ = try await channel.finish(acceptAlreadyClosed: true)
    }

    @Test("A body that arrives in chunks and reaches the limit exactly is accepted")
    func chunkedExact() async throws {
        let (channel, recorder) = try await harness(limits: Limits(maximumBodyBytes: 10))
        try await channel.writeInbound(head([("Host", "h"), ("Transfer-Encoding", "chunked")]))
        try await channel.writeInbound(HTTPServerRequestPart.body(ByteBuffer(string: "12345")))
        try await channel.writeInbound(HTTPServerRequestPart.body(ByteBuffer(string: "67890")))
        try await channel.writeInbound(HTTPServerRequestPart.end(nil))
        #expect(try await status(of: channel) == 200)
        #expect(await recorder.requests.first?.body.count == 10)
        _ = try await channel.finish(acceptAlreadyClosed: true)
    }

    @Test("A body timer left over from one request does not cut off the next")
    func staleBodyTimer() async throws {
        let (channel, _) = try await harness(limits: Limits(bodyReadTimeout: .seconds(30)))
        try await channel.writeInbound(head([("Host", "h"), ("Content-Length", "2")]))
        try await channel.writeInbound(HTTPServerRequestPart.body(ByteBuffer(string: "ab")))
        try await channel.writeInbound(HTTPServerRequestPart.end(nil))
        #expect(try await status(of: channel) == 200)

        await channel.testingEventLoop.advanceTime(by: .seconds(25))
        try await channel.writeInbound(head([("Host", "h"), ("Content-Length", "10")]))
        try await channel.writeInbound(HTTPServerRequestPart.body(ByteBuffer(string: "ab")))
        await channel.testingEventLoop.advanceTime(by: .seconds(6))   // 31 s after the first request's timer would have started
        #expect(channel.isActive, "the first request's body timer cut off the second request")
        _ = try await channel.finish(acceptAlreadyClosed: true)
    }

    @Test("When shutdown begins during a request, that request is answered with Connection: close and the connection ends")
    func quiesceDuringRequest() async throws {
        let gate = Gate()
        let (channel, _) = try await harness { _ in
            await gate.wait()
            return Response(status: .ok)
        }
        try await channel.writeInbound(head([("Host", "h")]))
        try await channel.writeInbound(HTTPServerRequestPart.end(nil))
        try await Task.sleep(for: .milliseconds(50))
        channel.pipeline.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent())
        try await Task.sleep(for: .milliseconds(50))
        #expect(channel.isActive, "the request in flight was cut off")
        await gate.open()
        var data = Data()
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline, !String(decoding: data, as: UTF8.self).contains("\r\n\r\n") {
            while let buffer = try await channel.readOutbound(as: ByteBuffer.self) { data.append(contentsOf: buffer.readableBytesView) }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(String(decoding: data, as: UTF8.self).lowercased().contains("connection: close"))
        #expect(!channel.isActive)
    }

    @Test("When shutdown begins on an idle connection, it closes at once")
    func quiesceWhenIdle() async throws {
        let (channel, _) = try await harness()
        channel.pipeline.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent())
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline, channel.isActive { try await Task.sleep(for: .milliseconds(2)) }
        #expect(!channel.isActive)
    }

    @Test("When the peer disconnects mid-request, the handler's task is cancelled")
    func cancellationOnDisconnect() async throws {
        let cancelled = FlagBox()
        let gate = Gate()
        let (channel, _) = try await harness { _ in
            await withTaskCancellationHandler {
                await gate.wait()
                return Response(status: .ok)
            } onCancel: {
                cancelled.set()
            }
        }
        try await channel.writeInbound(head([("Host", "h")]))
        try await channel.writeInbound(HTTPServerRequestPart.end(nil))
        try await Task.sleep(for: .milliseconds(50))
        try await channel.close()
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline, !cancelled.value { try await Task.sleep(for: .milliseconds(2)) }
        #expect(cancelled.value)
        await gate.open()
    }
}
