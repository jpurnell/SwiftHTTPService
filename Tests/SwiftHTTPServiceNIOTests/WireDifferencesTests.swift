import Foundation
import NIOConcurrencyHelpers
import SwiftHTTPService
import Testing
@testable import SwiftHTTPServiceNIO

/// The differences SwiftMoE's replay of its old server against the kit found (DesignProposal_0.6.0, section 2), each
/// decided and pinned here on a real socket.
@Suite("Wire differences", .serialized)
struct WireDifferencesTests {

    // MARK: A request that stops sending

    @Test("A body that stops arriving before its Content-Length is answered 408 at the body deadline, and the connection closes")
    func stalledBody() async throws {
        let running = try await startServer(limits: Limits(bodyReadTimeout: .milliseconds(300), idleTimeout: .seconds(30)))
        try await withClientGroup { group in
            let client = try await RawClient.connect(to: running.address, group: group)
            try await client.send("POST /x HTTP/1.1\r\nHost: h\r\nContent-Length: 10\r\n\r\nabc")
            let response = try #require(try await client.response())
            #expect(response.status == 408)
            #expect(response.header("Connection") == "close")
            #expect(response.body == Refusal.requestTimeout.body)
            #expect(try await client.waitUntilClosed())
        }
        await running.server.shutdown()
    }

    @Test("A client that connects and sends nothing is answered 408 at the idle timeout, and the connection closes")
    func silentFirstConnection() async throws {
        let seen = NIOLockedValueBox<[TransportRefusal]>([])
        let server = HTTPServer(
            configuration: try ServiceConfiguration(port: 0, limits: Limits(headerReadTimeout: .seconds(30), idleTimeout: .milliseconds(300))),
            handler: ok(), refusals: RefusalHooks(observe: { kind in seen.withLockedValue { $0.append(kind) } }))
        let address = try await server.start()
        try await withClientGroup { group in
            let client = try await RawClient.connect(to: address, group: group)
            let response = try #require(try await client.response())
            #expect(response.status == 408)
            #expect(response.header("Connection") == "close")
            #expect(response.body == Refusal.requestTimeout.body)
            #expect(try await client.waitUntilClosed())
        }
        await server.shutdown()
        #expect(seen.withLockedValue { $0 } == [.requestTimeout])
    }

    @Test("A keep-alive connection that goes quiet after a request is closed silently: it is idle, not late")
    func quietKeepAlive() async throws {
        let running = try await startServer(limits: Limits(idleTimeout: .milliseconds(400)))
        try await withClientGroup { group in
            let client = try await RawClient.connect(to: running.address, group: group)
            try await client.send("GET /x HTTP/1.1\r\nHost: h\r\n\r\n")
            let first = try #require(try await client.response())
            #expect(first.status == 200)
            let before = client.received.count
            #expect(try await client.waitUntilClosed(timeout: .seconds(5)))
            #expect(client.received.count == before, "a 408 was written to a connection that had been served")
        }
        await running.server.shutdown()
    }

    // MARK: A request line in another major version

    struct VersionCase: Sendable, CustomTestStringConvertible {
        let version: String
        let status: Int
        var testDescription: String { version }
    }

    // RFC 9112 section 2.3 and RFC 9110 section 15.6.6: a major version this server does not speak is 505; a version
    // that is not a version at all is 400. 1.x with another minor is left to the parser, which refuses it (400).
    static let versions: [VersionCase] = [
        VersionCase(version: "HTTP/2.0", status: 505), VersionCase(version: "HTTP/3.0", status: 505),
        VersionCase(version: "HTTP/0.9", status: 505), VersionCase(version: "HTTP/9.9", status: 505),
        VersionCase(version: "HTTP/1.2", status: 400), VersionCase(version: "HTTP/abc", status: 400),
        VersionCase(version: "HTTP/2", status: 400), VersionCase(version: "HTTP/2.0x", status: 400),
        VersionCase(version: "http/2.0", status: 400),
    ]

    @Test("A request line naming another HTTP major version is 505; a malformed version stays 400", arguments: versions)
    func versionLine(_ c: VersionCase) async throws {
        let running = try await startServer()
        try await withClientGroup { group in
            let client = try await RawClient.connect(to: running.address, group: group)
            try await client.send("GET /x \(c.version)\r\nHost: h\r\n\r\n")
            let response = try #require(try await client.response())
            #expect(response.status == c.status)
            if c.status == 505 {
                #expect(response.body == Refusal.versionNotSupported.body)
                #expect(response.header("Connection") == "close")
                #expect(response.statusLine == "HTTP/1.1 505 HTTP Version Not Supported")
            }
            #expect(try await client.waitUntilClosed())
        }
        await running.server.shutdown()
    }

    @Test("The version is found however the request line is split across packets")
    func versionLineSplit() async throws {
        let running = try await startServer()
        try await withClientGroup { group in
            let client = try await RawClient.connect(to: running.address, group: group)
            for piece in ["GET /x HT", "TP/", "2", ".", "0\r", "\nHost: h\r\n\r\n"] {
                try await client.send(piece)
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(try await client.response()?.status == 505)
        }
        await running.server.shutdown()
    }

    @Test("A 505 is counted and recorded like the other transport refusals, with no request line")
    func versionHooks() async throws {
        let seen = NIOLockedValueBox<[TransportRefusal]>([])
        let records = NIOLockedValueBox<[RefusalRecord]>([])
        let server = HTTPServer(
            configuration: try ServiceConfiguration(port: 0), handler: ok(),
            refusals: RefusalHooks(observe: { kind in seen.withLockedValue { $0.append(kind) } }, record: { record in records.withLockedValue { $0.append(record) } }))
        let address = try await server.start()
        try await withClientGroup { group in
            let client = try await RawClient.connect(to: address, group: group)
            try await client.send("GET /x HTTP/2.0\r\nHost: h\r\n\r\n")
            #expect(try await client.response()?.status == 505)
        }
        await server.shutdown()
        #expect(seen.withLockedValue { $0 } == [.versionNotSupported])
        #expect(records.withLockedValue { $0 }.map(\.kind) == [.versionNotSupported])
    }

    @Test("A supported request after a first one on the same connection is still checked: the second line's version counts too")
    func versionOnASecondRequest() async throws {
        let running = try await startServer()
        try await withClientGroup { group in
            let client = try await RawClient.connect(to: running.address, group: group)
            try await client.send("GET /x HTTP/1.1\r\nHost: h\r\n\r\n")
            #expect(try await client.response()?.status == 200)
            let before = client.received.count
            try await client.send("GET /y HTTP/2.0\r\nHost: h\r\n\r\n")
            let deadline = ContinuousClock.now + .seconds(5)
            while client.received.count == before, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(String(decoding: client.received.dropFirst(before), as: UTF8.self).hasPrefix("HTTP/1.1 505 "))
        }
        await running.server.shutdown()
    }

    // MARK: The reason phrase

    @Test("A body over the bound is answered 413 with the phrase RFC 9110 now uses, before any credential could be read")
    func contentTooLarge() async throws {
        let running = try await startServer(limits: Limits(maximumBodyBytes: 10), handler: { _ in
            Issue.record("the handler ran for a refused body")
            return Response(status: .ok)
        })
        try await withClientGroup { group in
            let client = try await RawClient.connect(to: running.address, group: group)
            // No credential is sent, and none is asked for: the transport refuses the size before the handler is reached.
            try await client.send("POST /x HTTP/1.1\r\nHost: h\r\nContent-Length: 11\r\n\r\n")
            let response = try #require(try await client.response())
            #expect(response.statusLine == "HTTP/1.1 413 Content Too Large")
            #expect(response.body == Refusal.bodyTooLarge.body)
        }
        await running.server.shutdown()
    }

    struct PhraseCase: Sendable, CustomTestStringConvertible {
        let code: Int
        let line: String
        var testDescription: String { "\(code)" }
    }

    // The three phrases RFC 9110 renamed, and two that did not change, so that the table is not everything-custom.
    static let phrases: [PhraseCase] = [
        PhraseCase(code: 413, line: "HTTP/1.1 413 Content Too Large"),
        PhraseCase(code: 416, line: "HTTP/1.1 416 Range Not Satisfiable"),
        PhraseCase(code: 422, line: "HTTP/1.1 422 Unprocessable Content"),
        PhraseCase(code: 404, line: "HTTP/1.1 404 Not Found"),
        PhraseCase(code: 503, line: "HTTP/1.1 503 Service Unavailable"),
    ]

    @Test("A handler's own status is written with the current phrase", arguments: phrases)
    func handlerStatus(_ c: PhraseCase) async throws {
        let running = try await startServer(handler: { _ in Response(status: .init(code: c.code)) })
        try await withClientGroup { group in
            let client = try await RawClient.connect(to: running.address, group: group)
            try await client.send("GET /x HTTP/1.1\r\nHost: h\r\n\r\n")
            #expect(try await client.response()?.statusLine == c.line)
        }
        await running.server.shutdown()
    }
}
