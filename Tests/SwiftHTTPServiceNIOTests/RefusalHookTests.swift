import Foundation
import HTTPTypes
import NIOConcurrencyHelpers
import NIOPosix
import SwiftHTTPService
import SwiftTLSKit
import Testing
@testable import SwiftHTTPServiceNIO

/// The transport's own refusals can be given a body of the server's choosing, and counted. The status, and
/// what the connection does next, stay the transport's: a hook that could change them could turn a refusal of
/// a smuggling attempt into a `200`.
@Suite("Transport refusal hook", .serialized)
struct RefusalHookTests {

    /// Each kind, the status the transport gives it (RFC 9110 and RFC 6585 as the transport uses them), and how to cause it.
    struct Case: Sendable, CustomTestStringConvertible {
        let kind: TransportRefusal
        let status: Int
        let limits: @Sendable () -> Limits
        let wire: String
        let handler: Handler
        var testDescription: String { "\(kind)" }
    }

    private static let throwing: Handler = { _ in throw HookTestError() }
    private struct HookTestError: Error {}

    static let cases: [Case] = [
        Case(kind: .badRequest, status: 400, limits: { Limits() },
             wire: "GET /x HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n", handler: ok()),
        Case(kind: .malformedTarget, status: 400, limits: { Limits() },
             wire: "GET //a HTTP/1.1\r\nHost: h\r\n\r\n", handler: ok()),
        Case(kind: .requestTimeout, status: 408, limits: { var l = Limits(); l.headerReadTimeout = .milliseconds(150); return l },
             wire: "GET /x HTTP/1.1\r\nHost: h\r\n", handler: ok()),
        Case(kind: .bodyTooLarge, status: 413, limits: { var l = Limits(); l.maximumBodyBytes = 10; return l },
             wire: "POST /x HTTP/1.1\r\nHost: h\r\nContent-Length: 100\r\n\r\n", handler: ok()),
        Case(kind: .expectationFailed, status: 417, limits: { Limits() },
             wire: "GET /x HTTP/1.1\r\nHost: h\r\nExpect: magic\r\n\r\n", handler: ok()),
        Case(kind: .headersTooLarge, status: 431, limits: { var l = Limits(); l.maximumHeaderBytes = 1024; return l },
             wire: "GET /x HTTP/1.1\r\nHost: h\r\nX-Big: \(String(repeating: "a", count: 2000))\r\n\r\n", handler: ok()),
        Case(kind: .internalError, status: 500, limits: { Limits() },
             wire: "GET /x HTTP/1.1\r\nHost: h\r\n\r\n", handler: RefusalHookTests.throwing),
    ]

    private func hooks(into seen: NIOLockedValueBox<[TransportRefusal]>) -> RefusalHooks {
        RefusalHooks(
            respond: { refusal in
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                if let name = HTTPField.Name("X-Custom") { headers[name] = refusal.code }
                // A status here is ignored: the transport's stays.
                return Response(status: .ok, headers: headers, body: Data(#"{"custom":"\#(refusal.code)"}"#.utf8))
            },
            observe: { refusal in seen.withLockedValue { $0.append(refusal) } })
    }

    @Test("Over HTTP/1.1 every kind of refusal uses the server's body and headers, keeps the transport's status, and is counted once", arguments: cases)
    func http1(_ c: Case) async throws {
        let seen = NIOLockedValueBox<[TransportRefusal]>([])
        let server = HTTPServer(configuration: try ServiceConfiguration(port: 0, limits: c.limits()), handler: c.handler, refusals: hooks(into: seen))
        let address = try await server.start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        try await client.send(c.wire)
        let response = try #require(try await client.response())
        #expect(response.status == c.status)                                      // not the 200 the hook asked for
        #expect(response.text == #"{"custom":"\#(c.kind.code)"}"#)
        #expect(response.header("Content-Type") == "application/json")
        #expect(response.header("X-Custom") == c.kind.code)
        #expect(response.header("Connection") == "close")                         // still the transport's decision
        #expect(try await client.waitUntilClosed())
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
        #expect(seen.withLockedValue { $0 } == [c.kind])
    }

    @Test("Without hooks the fixed bodies are unchanged")
    func defaults() async throws {
        let running = try await startServer()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: running.address, group: group)
        try await client.send("GET /x HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n")
        let response = try #require(try await client.response())
        #expect(response.status == 400)
        #expect(response.body == Refusal.badRequest.body)
        await client.close()
        try await group.shutdownGracefully()
        await running.server.shutdown()
    }

    @Test("A responder that returns nil keeps the fixed body, and the observer still hears of it")
    func nilKeepsTheDefault() async throws {
        let seen = NIOLockedValueBox<[TransportRefusal]>([])
        let server = HTTPServer(
            configuration: try ServiceConfiguration(port: 0), handler: ok(),
            refusals: RefusalHooks(respond: { _ in nil }, observe: { refusal in seen.withLockedValue { $0.append(refusal) } }))
        let address = try await server.start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        try await client.send("GET /x HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n")
        let response = try #require(try await client.response())
        #expect(response.body == Refusal.badRequest.body)
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
        #expect(seen.withLockedValue { $0 } == [.badRequest])
    }

    @Test("A response is not a refusal: a handler's own 4xx is not passed to the hooks")
    func handlerResponsesAreNotRefusals() async throws {
        let seen = NIOLockedValueBox<[TransportRefusal]>([])
        let server = HTTPServer(
            configuration: try ServiceConfiguration(port: 0), handler: { _ in Response(status: .badRequest) },
            refusals: hooks(into: seen))
        let address = try await server.start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        try await client.send("GET /x HTTP/1.1\r\nHost: h\r\n\r\n")
        let response = try #require(try await client.response())
        #expect(response.status == 400)
        #expect(response.body.isEmpty)
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
        #expect(seen.withLockedValue { $0 }.isEmpty)
    }

    @Test("Each public kind has the status and code the transport has always used")
    func publicKinds() {
        let expected: [(TransportRefusal, Int, String)] = [
            (.badRequest, 400, "bad_request"), (.malformedTarget, 400, "malformed_target"), (.requestTimeout, 408, "request_timeout"),
            (.bodyTooLarge, 413, "body_too_large"), (.expectationFailed, 417, "expectation_failed"),
            (.headersTooLarge, 431, "headers_too_large"), (.internalError, 500, "internal_error"),
            (.busy, 503, "service_unavailable"), (.versionNotSupported, 505, "http_version_not_supported"),
        ]
        #expect(TransportRefusal.allCases.count == expected.count)
        for (kind, status, code) in expected {
            #expect(kind.statusCode == status)
            #expect(kind.code == code)
        }
    }

    // MARK: HTTP/2

    struct H2Case: Sendable, CustomTestStringConvertible {
        let kind: TransportRefusal
        let status: Int
        let limits: @Sendable () -> Limits
        let block: [(String, String)]
        let handler: Handler
        let leaveOpen: Bool
        var testDescription: String { "\(kind)" }
    }

    private static let get: [(String, String)] = [(":method", "GET"), (":scheme", "https"), (":path", "/x"), (":authority", "localhost")]

    static let h2Cases: [H2Case] = [
        H2Case(kind: .malformedTarget, status: 400, limits: { Limits() },
               block: [(":method", "GET"), (":scheme", "https"), (":path", "//a"), (":authority", "localhost")], handler: ok(), leaveOpen: false),
        H2Case(kind: .badRequest, status: 400, limits: { Limits() }, block: get + [("host", "elsewhere")], handler: ok(), leaveOpen: false),
        H2Case(kind: .expectationFailed, status: 417, limits: { Limits() }, block: get + [("expect", "magic")], handler: ok(), leaveOpen: false),
        H2Case(kind: .headersTooLarge, status: 431, limits: { var l = Limits(); l.maximumHeaderCount = 2; return l },
               block: get + [("a", "1"), ("b", "2"), ("c", "3")], handler: ok(), leaveOpen: false),
        H2Case(kind: .bodyTooLarge, status: 413, limits: { var l = Limits(); l.maximumBodyBytes = 10; return l },
               block: [(":method", "POST"), (":scheme", "https"), (":path", "/x"), ("content-length", "11")], handler: ok(), leaveOpen: true),
        H2Case(kind: .requestTimeout, status: 408, limits: { var l = Limits(); l.bodyReadTimeout = .milliseconds(150); return l },
               block: [(":method", "POST"), (":scheme", "https"), (":path", "/x"), ("content-length", "5")], handler: ok(), leaveOpen: true),
        H2Case(kind: .internalError, status: 500, limits: { Limits() }, block: get, handler: RefusalHookTests.throwing, leaveOpen: false),
    ]

    @Test("Over HTTP/2 the same hooks apply, with the same status", arguments: h2Cases)
    func http2(_ c: H2Case) async throws {
        let seen = NIOLockedValueBox<[TransportRefusal]>([])
        let material = try TestTLS()
        defer { material.cleanUp() }
        let server = HTTPServer(
            configuration: try ServiceConfiguration(port: 0, tls: material.files, limits: c.limits()), handler: c.handler,
            refusals: hooks(into: seen))
        let address = try await server.start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await H2Client.connect(
            to: address, group: group, tls: try material.clientContext(applicationProtocols: ["h2"]), lenient: true)
        let response = try await client.send(block: c.block, leaveOpen: c.leaveOpen)
        #expect(response.status == c.status)
        #expect(response.text == #"{"custom":"\#(c.kind.code)"}"#)
        #expect(response.header("x-custom") == c.kind.code)
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
        #expect(seen.withLockedValue { $0 } == [c.kind])
    }
}
