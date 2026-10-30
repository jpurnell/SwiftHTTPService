import Foundation
import NIOConcurrencyHelpers
import NIOPosix
import SwiftHTTPService
import Testing
@testable import SwiftHTTPServiceNIO

/// The record a server is given of each refusal: who asked and, when the request line was read, what for. The
/// request line comes from a stranger and is going to be written in a log, so it is escaped and cut short.
@Suite("Refusal records", .serialized)
struct RefusalRecordTests {

    // MARK: The text of a target

    struct Case: Sendable, CustomTestStringConvertible {
        let input: [UInt8]
        let expected: String
        var testDescription: String { expected }
    }

    // Worked out by hand: a byte from 0x21 to 0x7E is kept as written (including % and quotes, which a log formatter
    // escapes for itself); every other byte is %XX in upper-case hex, so nothing a stranger sent can end a log line.
    static let targets: [Case] = [
        Case(input: Array("/x".utf8), expected: "/x"),
        Case(input: Array("/a%20b?c=d".utf8), expected: "/a%20b?c=d"),
        Case(input: Array("/a b".utf8), expected: "/a%20b"),
        Case(input: Array("/caf\u{E9}".utf8), expected: "/caf%C3%A9"),                  // UTF-8 for e-acute is C3 A9
        Case(input: Array("/a\r\nSet-Cookie: x".utf8), expected: "/a%0D%0ASet-Cookie:%20x"),
        Case(input: [0x2F, 0x00, 0x7F], expected: "/%00%7F"),
        Case(input: Array("/\"\\".utf8), expected: "/\"\\"),
        Case(input: [0xFF, 0xFE], expected: "%FF%FE"),                                     // not UTF-8 at all, still safe
        Case(input: [], expected: ""),
    ]

    @Test("A target is shown with every byte outside visible ASCII escaped", arguments: targets)
    func escaping(_ c: Case) {
        #expect(RefusalRecord.text(ofTarget: c.input) == c.expected)
    }

    @Test("A target of 512 characters is shown whole; one more is cut at 512 and marked")
    func truncation() {
        let exact = [UInt8](repeating: 0x61, count: 512)
        #expect(RefusalRecord.text(ofTarget: exact) == String(repeating: "a", count: 512))
        let over = [UInt8](repeating: 0x61, count: 513)
        #expect(RefusalRecord.text(ofTarget: over) == String(repeating: "a", count: 512) + "...")
        // Escapes count as the characters they are: 171 escaped bytes are 513 characters.
        let escaped = [UInt8](repeating: 0x20, count: 171)
        #expect(RefusalRecord.text(ofTarget: escaped) == String(repeating: "%20", count: 170) + "%2" + "...")
    }

    @Test("A method is shown only if it is a token of at most 32 characters; anything else is not shown")
    func methods() {
        #expect(RefusalRecord.text(ofMethod: Array("GET".utf8)) == "GET")
        #expect(RefusalRecord.text(ofMethod: Array("M-SEARCH".utf8)) == "M-SEARCH")
        #expect(RefusalRecord.text(ofMethod: Array("H2X0".utf8)) == "H2X0")             // digits are token characters
        #expect(RefusalRecord.text(ofMethod: Array(String(repeating: "A", count: 32).utf8)) == String(repeating: "A", count: 32))
        #expect(RefusalRecord.text(ofMethod: Array(String(repeating: "A", count: 33).utf8)) == nil)
        #expect(RefusalRecord.text(ofMethod: Array("G ET".utf8)) == nil)
        #expect(RefusalRecord.text(ofMethod: Array("GET\r\n".utf8)) == nil)
        #expect(RefusalRecord.text(ofMethod: Array("G\"T".utf8)) == nil)
        #expect(RefusalRecord.text(ofMethod: []) == nil)
    }

    // MARK: Over HTTP/1.1

    struct Wire: Sendable, CustomTestStringConvertible {
        let kind: TransportRefusal
        let limits: @Sendable () -> Limits
        let wire: String
        let handler: Handler
        let method: String?
        let target: String?
        var testDescription: String { "\(kind) \(target ?? "no request line")" }
    }

    private static let throwing: Handler = { _ in throw RecordTestError() }
    private struct RecordTestError: Error {}

    static let wires: [Wire] = [
        Wire(kind: .badRequest, limits: { Limits() }, wire: "GET /x HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n", handler: ok(), method: "GET", target: "/x"),
        Wire(kind: .malformedTarget, limits: { Limits() }, wire: "GET //a HTTP/1.1\r\nHost: h\r\n\r\n", handler: ok(), method: "GET", target: "//a"),
        Wire(kind: .malformedTarget, limits: { Limits() }, wire: "GET /a/../b HTTP/1.1\r\nHost: h\r\n\r\n", handler: ok(), method: "GET", target: "/a/../b"),
        Wire(kind: .bodyTooLarge, limits: { var l = Limits(); l.maximumBodyBytes = 10; return l },
             wire: "POST /up HTTP/1.1\r\nHost: h\r\nContent-Length: 100\r\n\r\n", handler: ok(), method: "POST", target: "/up"),
        Wire(kind: .expectationFailed, limits: { Limits() }, wire: "GET /x HTTP/1.1\r\nHost: h\r\nExpect: magic\r\n\r\n", handler: ok(), method: "GET", target: "/x"),
        Wire(kind: .internalError, limits: { Limits() }, wire: "GET /boom?token=secret HTTP/1.1\r\nHost: h\r\n\r\n", handler: RefusalRecordTests.throwing, method: "GET", target: "/boom?token=secret"),
        Wire(kind: .requestTimeout, limits: { var l = Limits(); l.headerReadTimeout = .milliseconds(150); return l },
             wire: "GET /x HTTP/1.1\r\nHost: h\r\n", handler: ok(), method: nil, target: nil),
        Wire(kind: .headersTooLarge, limits: { var l = Limits(); l.maximumHeaderBytes = 1024; return l },
             wire: "GET /x HTTP/1.1\r\nHost: h\r\nX-Big: \(String(repeating: "a", count: 2000))\r\n\r\n", handler: ok(), method: nil, target: nil),
    ]

    private func records(_ server: HTTPServer) async throws -> (BoundAddress) { try await server.start() }

    @Test("Over HTTP/1.1 each refusal carries the peer and, when the request line had been read, its method and target", arguments: wires)
    func http1(_ c: Wire) async throws {
        let seen = NIOLockedValueBox<[RefusalRecord]>([])
        let observed = NIOLockedValueBox(0)
        let server = HTTPServer(
            configuration: try ServiceConfiguration(port: 0, limits: c.limits()), handler: c.handler,
            refusals: RefusalHooks(observe: { _ in observed.withLockedValue { $0 += 1 } }, record: { record in seen.withLockedValue { $0.append(record) } }))
        let address = try await server.start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        try await client.send(c.wire)
        #expect(try await client.response()?.status == c.kind.statusCode)         // the refusal itself was written
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
        let records = seen.withLockedValue { $0 }
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.kind == c.kind)
        #expect(record.peerAddress == "127.0.0.1")
        #expect(record.remoteAddress == "127.0.0.1")
        #expect(record.method == c.method)
        #expect(record.target == c.target)
        #expect(observed.withLockedValue { $0 } == 1)                        // the older hook still hears of it, once
    }

    @Test("A request line that is not valid HTTP leaves no method or target, but the peer is still there")
    func garbage() async throws {
        let seen = NIOLockedValueBox<[RefusalRecord]>([])
        let server = HTTPServer(
            configuration: try ServiceConfiguration(port: 0), handler: ok(),
            refusals: RefusalHooks(record: { record in seen.withLockedValue { $0.append(record) } }))
        let address = try await server.start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        try await client.send("\u{1}\u{2}\u{3} not http at all\r\n\r\n")
        #expect(try await client.waitUntilClosed())
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
        let record = try #require(seen.withLockedValue { $0 }.first)
        #expect(record.kind == .badRequest)
        #expect(record.peerAddress == "127.0.0.1")
        #expect(record.method == nil)
        #expect(record.target == nil)
    }

    @Test("A refusal on a later request of a kept-alive connection does not borrow the request line of an earlier one")
    func noStaleLine() async throws {
        let seen = NIOLockedValueBox<[RefusalRecord]>([])
        let server = HTTPServer(
            configuration: try ServiceConfiguration(port: 0), handler: ok(),
            refusals: RefusalHooks(record: { record in seen.withLockedValue { $0.append(record) } }))
        let address = try await server.start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        try await client.send("GET /served HTTP/1.1\r\nHost: h\r\n\r\n")
        #expect(try await client.response()?.status == 200)
        let before = client.received.count
        try await client.send("\u{1}\u{2}\u{3} not http at all\r\n\r\n")                 // no request line to be had
        let deadline = ContinuousClock.now + .seconds(3)
        while client.received.count == before, !client.isClosed, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
        let record = try #require(seen.withLockedValue { $0 }.first)
        #expect(seen.withLockedValue { $0.count } == 1)
        #expect(record.method == nil)
        #expect(record.target == nil)                                         // not "/served"
    }

    @Test("An HTTP/1.0 request that is refused says HTTP/1.0, and an HTTP/1.1 one says HTTP/1.1")
    func versions() async throws {
        let seen = NIOLockedValueBox<[RefusalRecord]>([])
        let server = HTTPServer(
            configuration: try ServiceConfiguration(port: 0), handler: ok(),
            refusals: RefusalHooks(record: { record in seen.withLockedValue { $0.append(record) } }))
        let address = try await server.start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        for line in ["GET //a HTTP/1.0\r\n\r\n", "GET //a HTTP/1.1\r\nHost: h\r\n\r\n"] {
            let client = try await RawClient.connect(to: address, group: group)
            try await client.send(line)
            _ = try await client.response()
            await client.close()
        }
        try await group.shutdownGracefully()
        await server.shutdown()
        #expect(seen.withLockedValue { $0 }.map(\.httpVersion) == [.http1_0, .http1_1])
    }

    @Test("A target that spells a line break in percent-escapes stays text and never becomes one")
    func hostileTarget() async throws {
        let seen = NIOLockedValueBox<[RefusalRecord]>([])
        let server = HTTPServer(
            configuration: try ServiceConfiguration(port: 0), handler: ok(),
            refusals: RefusalHooks(record: { record in seen.withLockedValue { $0.append(record) } }))
        let address = try await server.start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        try await client.send("GET //x%0d%0aSet-Cookie:%20a HTTP/1.1\r\nHost: h\r\n\r\n")
        _ = try await client.response()
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
        let record = try #require(seen.withLockedValue { $0 }.first)
        let target = try #require(record.target)
        #expect(target == "//x%0d%0aSet-Cookie:%20a")                         // the characters it was written with
        #expect(target.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F })
    }

    @Test("Behind a trusted proxy the record's remote address is the client the proxy reported, and the peer stays the socket's")
    func proxied() async throws {
        let seen = NIOLockedValueBox<[RefusalRecord]>([])
        let server = HTTPServer(
            configuration: try ServiceConfiguration(port: 0, trustedProxies: ["127.0.0.0/8"], forwarding: .xForwardedFor), handler: ok(),
            refusals: RefusalHooks(record: { record in seen.withLockedValue { $0.append(record) } }))
        let address = try await server.start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        try await client.send("GET //a HTTP/1.1\r\nHost: h\r\nX-Forwarded-For: 1.1.1.1, 203.0.113.9\r\n\r\n")
        _ = try await client.response()
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
        let record = try #require(seen.withLockedValue { $0 }.first)
        #expect(record.peerAddress == "127.0.0.1")
        #expect(record.remoteAddress == "203.0.113.9")
    }

    // MARK: Over HTTP/2

    @Test("Over HTTP/2 behind a trusted proxy the record's remote address is the client the proxy reported")
    func http2Proxied() async throws {
        let seen = NIOLockedValueBox<[RefusalRecord]>([])
        let material = try TestTLS()
        defer { material.cleanUp() }
        let server = HTTPServer(
            configuration: try ServiceConfiguration(port: 0, tls: material.files, trustedProxies: ["127.0.0.0/8"], forwarding: .xForwardedFor),
            handler: ok(), refusals: RefusalHooks(record: { record in seen.withLockedValue { $0.append(record) } }))
        let address = try await server.start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await H2Client.connect(to: address, group: group, tls: try material.clientContext(applicationProtocols: ["h2"]), lenient: true)
        _ = try await client.send(block: [(":method", "GET"), (":scheme", "https"), (":path", "//a"), (":authority", "localhost"),
                                          ("x-forwarded-for", "1.1.1.1, 203.0.113.9")])
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
        let record = try #require(seen.withLockedValue { $0 }.first)
        #expect(record.peerAddress == "127.0.0.1")
        #expect(record.remoteAddress == "203.0.113.9")
    }

    struct H2Wire: Sendable, CustomTestStringConvertible {
        let kind: TransportRefusal
        let limits: @Sendable () -> Limits
        let block: [(String, String)]
        let handler: Handler
        let leaveOpen: Bool
        let method: String
        let target: String
        var testDescription: String { "\(kind)" }
    }

    private static let get: [(String, String)] = [(":method", "GET"), (":scheme", "https"), (":path", "/x"), (":authority", "localhost")]

    static let h2Wires: [H2Wire] = [
        H2Wire(kind: .malformedTarget, limits: { Limits() }, block: [(":method", "GET"), (":scheme", "https"), (":path", "//a"), (":authority", "localhost")],
               handler: ok(), leaveOpen: false, method: "GET", target: "//a"),
        H2Wire(kind: .badRequest, limits: { Limits() }, block: get + [("host", "elsewhere")], handler: ok(), leaveOpen: false, method: "GET", target: "/x"),
        H2Wire(kind: .headersTooLarge, limits: { var l = Limits(); l.maximumHeaderCount = 2; return l }, block: get + [("a", "1"), ("b", "2"), ("c", "3")],
               handler: ok(), leaveOpen: false, method: "GET", target: "/x"),
        H2Wire(kind: .bodyTooLarge, limits: { var l = Limits(); l.maximumBodyBytes = 10; return l },
               block: [(":method", "POST"), (":scheme", "https"), (":path", "/up"), ("content-length", "11")], handler: ok(), leaveOpen: true, method: "POST", target: "/up"),
        H2Wire(kind: .requestTimeout, limits: { var l = Limits(); l.bodyReadTimeout = .milliseconds(150); return l },
               block: [(":method", "POST"), (":scheme", "https"), (":path", "/slow"), ("content-length", "5")], handler: ok(), leaveOpen: true, method: "POST", target: "/slow"),
        H2Wire(kind: .internalError, limits: { Limits() }, block: get, handler: RefusalRecordTests.throwing, leaveOpen: false, method: "GET", target: "/x"),
    ]

    @Test("Over HTTP/2 each refusal carries the peer, the method and the target, and says HTTP/2", arguments: h2Wires)
    func http2(_ c: H2Wire) async throws {
        let seen = NIOLockedValueBox<[RefusalRecord]>([])
        let material = try TestTLS()
        defer { material.cleanUp() }
        let server = HTTPServer(
            configuration: try ServiceConfiguration(port: 0, tls: material.files, limits: c.limits()), handler: c.handler,
            refusals: RefusalHooks(record: { record in seen.withLockedValue { $0.append(record) } }))
        let address = try await server.start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await H2Client.connect(
            to: address, group: group, tls: try material.clientContext(applicationProtocols: ["h2"]), lenient: true)
        _ = try await client.send(block: c.block, leaveOpen: c.leaveOpen)
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
        let record = try #require(seen.withLockedValue { $0 }.first)
        #expect(seen.withLockedValue { $0.count } == 1)
        #expect(record.kind == c.kind)
        #expect(record.peerAddress == "127.0.0.1")
        #expect(record.method == c.method)
        #expect(record.target == c.target)
        #expect(record.httpVersion == .http2)
    }
}
