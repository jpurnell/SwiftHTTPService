import Foundation
import NIOPosix
import SwiftHTTPService
import SwiftTLSKit
import SwiftTLSKitTestSupport
import Testing
@testable import SwiftHTTPServiceNIO

/// What the server does with an HTTP/2 request that is malformed, or that this server will not serve.
///
/// The expectations come from RFC 9113, not from what the server was seen to do. Section 8.1.1: a malformed
/// request "MUST be treated as a stream error of type PROTOCOL_ERROR", which is a RST_STREAM carrying code 1.
/// A request that is well formed and refused on this server's own policy (a target the core will not parse, a
/// body past the bound, trailers) is answered with the fixed problem response, as it is over HTTP/1.1.
@Suite("HTTP/2 request validation", .serialized)
struct HTTP2ValidationTests {

    /// What the client saw.
    enum Outcome: Equatable, CustomStringConvertible {
        case status(Int)
        case reset(Int)
        case closed
        case nothing

        init(_ response: H2Response) {
            if let status = response.status { self = .status(status) }
            else if let code = response.resetCode { self = .reset(code) }
            else if response.closed { self = .closed }
            else { self = .nothing }
        }

        var description: String {
            switch self {
            case .status(let code): "status \(code)"
            case .reset(let code): "RST_STREAM \(code)"
            case .closed: "connection closed"
            case .nothing: "nothing within the timeout"
            }
        }
    }

    static let protocolError = 1   // RFC 9113 section 7

    private static let good: [(String, String)] = [
        (":method", "GET"), (":scheme", "https"), (":path", "/x"), (":authority", "localhost"),
    ]

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let block: [(String, String)]
        var body: Data?
        var trailers: [(String, String)]?
        let expected: Outcome
        var testDescription: String { name }
    }

    private static func without(_ pseudo: String) -> [(String, String)] { good.filter { $0.0 != pseudo } }

    // MARK: Malformed: a stream error of type PROTOCOL_ERROR (RFC 9113 sections 8.1.1, 8.2, 8.3)

    static let malformed: [Case] = [
        Case(name: "no :method", block: without(":method"), expected: .reset(protocolError)),
        Case(name: "no :scheme", block: without(":scheme"), expected: .reset(protocolError)),
        Case(name: "no :path", block: without(":path"), expected: .reset(protocolError)),
        Case(name: "a repeated :method", block: good + [(":method", "POST")], expected: .reset(protocolError)),
        Case(name: "a repeated :path", block: good + [(":path", "/y")], expected: .reset(protocolError)),
        Case(name: "a pseudo-header after a regular field", block: [(":method", "GET"), ("x-a", "1"), (":scheme", "https"), (":path", "/x")],
             expected: .reset(protocolError)),
        Case(name: "an unknown pseudo-header", block: good + [(":nonsense", "1")], expected: .reset(protocolError)),
        Case(name: "a response pseudo-header in a request", block: good + [(":status", "200")], expected: .reset(protocolError)),
        Case(name: "an empty :path", block: [(":method", "GET"), (":scheme", "https"), (":path", ""), (":authority", "localhost")],
             expected: .reset(protocolError)),
        Case(name: "an upper-case field name", block: good + [("X-Thing", "1")], expected: .reset(protocolError)),
        Case(name: "a Connection field", block: good + [("connection", "keep-alive")], expected: .reset(protocolError)),
        Case(name: "a Keep-Alive field", block: good + [("keep-alive", "timeout=5")], expected: .reset(protocolError)),
        Case(name: "a Proxy-Connection field", block: good + [("proxy-connection", "keep-alive")], expected: .reset(protocolError)),
        Case(name: "a Transfer-Encoding field", block: good + [("transfer-encoding", "chunked")], expected: .reset(protocolError)),
        Case(name: "an Upgrade field", block: good + [("upgrade", "websocket")], expected: .reset(protocolError)),
        Case(name: "a TE field other than trailers", block: good + [("te", "gzip")], expected: .reset(protocolError)),
        Case(name: "a field value with a line feed", block: good + [("x-a", "a\nb")], expected: .reset(protocolError)),
        Case(name: "a field value with a carriage return", block: good + [("x-a", "a\rb")], expected: .reset(protocolError)),
        Case(name: "a field value with a NUL", block: good + [("x-a", "a\u{0}b")], expected: .reset(protocolError)),
        Case(name: "a Content-Length that is not digits", block: good + [("content-length", "abc")], expected: .reset(protocolError)),
        Case(name: "two different Content-Lengths", block: good + [("content-length", "3"), ("content-length", "4")], body: Data("abc".utf8),
             expected: .reset(protocolError)),
        Case(name: "a Content-Length longer than the body", block: [(":method", "POST"), (":scheme", "https"), (":path", "/x"), ("content-length", "5")],
             body: Data("abc".utf8), expected: .reset(protocolError)),
        Case(name: "a Content-Length shorter than the body", block: [(":method", "POST"), (":scheme", "https"), (":path", "/x"), ("content-length", "2")],
             body: Data("abc".utf8), expected: .reset(protocolError)),
    ]

    @Test("A malformed request is a stream error of type PROTOCOL_ERROR", arguments: malformed)
    func malformedRequests(_ c: Case) async throws {
        let actual = try await outcome(of: c)
        #expect(actual == c.expected, "saw \(actual)")
    }

    // MARK: Well formed, refused on this server's policy: the fixed problem response

    static let refusedByPolicy: [Case] = [
        Case(name: "a target the core refuses (//a)", block: [(":method", "GET"), (":scheme", "https"), (":path", "//a"), (":authority", "localhost")],
             expected: .status(400)),
        Case(name: "a target that is not origin-form", block: [(":method", "GET"), (":scheme", "https"), (":path", "a"), (":authority", "localhost")],
             expected: .status(400)),
        Case(name: "two identical Content-Lengths", block: [(":method", "POST"), (":scheme", "https"), (":path", "/x"), ("content-length", "3"), ("content-length", "3")],
             body: Data("abc".utf8), expected: .status(400)),
        Case(name: "Host and :authority that disagree", block: good + [("host", "elsewhere")], expected: .status(400)),
        Case(name: "an Expect other than 100-continue", block: good + [("expect", "magic")], expected: .status(417)),
        Case(name: "trailers from the client", block: [(":method", "POST"), (":scheme", "https"), (":path", "/x")], body: Data("abc".utf8),
             trailers: [("x-sum", "1")], expected: .reset(protocolError)),
    ]

    @Test("A well-formed request this server will not serve is refused with the fixed response", arguments: refusedByPolicy)
    func refused(_ c: Case) async throws {
        let actual = try await outcome(of: c)
        #expect(actual == c.expected, "saw \(actual)")
    }

    /// A space in the target is malformed whichever layer notices (RFC 9113 sections 8.1.1 and 8.3.1): the
    /// protocol layer resets the stream, or this server's own rule answers 400. Both conform, so both pass.
    @Test("A target with a space is refused, by a reset or by the fixed 400")
    func targetWithASpace() async throws {
        let c = Case(name: "space", block: [(":method", "GET"), (":scheme", "https"), (":path", "/a b"), (":authority", "localhost")], expected: .status(400))
        let actual = try await outcome(of: c)
        #expect([Outcome.reset(Self.protocolError), Outcome.status(400)].contains(actual), "saw \(actual)")
    }

    // MARK: Well formed and served

    static let served: [Case] = [
        Case(name: "the plain request", block: good, expected: .status(200)),
        Case(name: "no :authority and no Host (both are optional in HTTP/2)", block: without(":authority"), expected: .status(200)),
        Case(name: "Host alone, with no :authority", block: without(":authority") + [("host", "localhost")], expected: .status(200)),
        Case(name: "Host equal to :authority", block: good + [("host", "localhost")], expected: .status(200)),
        Case(name: "TE: trailers", block: good + [("te", "trailers")], expected: .status(200)),
        Case(name: "an Expect: 100-continue", block: good + [("expect", "100-continue")], expected: .status(200)),
        Case(name: "a query string", block: [(":method", "GET"), (":scheme", "https"), (":path", "/x?a=1&b=2"), (":authority", "localhost")],
             expected: .status(200)),
        Case(name: "a Content-Length equal to the body", block: [(":method", "POST"), (":scheme", "https"), (":path", "/x"), ("content-length", "3")],
             body: Data("abc".utf8), expected: .status(200)),
    ]

    @Test("A well-formed request is served", arguments: served)
    func accepted(_ c: Case) async throws {
        let actual = try await outcome(of: c)
        #expect(actual == c.expected, "saw \(actual)")
    }

    // MARK: Bounds

    @Test("A declared body past the bound is answered 413 and the stream is then reset with NO_ERROR (RFC 9113 section 8.1)")
    func declaredBodyTooLarge() async throws {
        var limits = Limits()
        limits.maximumBodyBytes = 10
        let response = try await exchange(limits: limits, block: [(":method", "POST"), (":scheme", "https"), (":path", "/x"), ("content-length", "11")],
                                          body: nil, keepOpen: true, awaitReset: true)
        #expect(response.status == 413)
        #expect(response.body == Refusal.bodyTooLarge.body, "body was \(response.text.debugDescription), \(response.headers)")
        #expect(response.resetCode == 0)
    }

    @Test("A body that grows past the bound without a declared length is answered 413 at the bound")
    func undeclaredBodyTooLarge() async throws {
        var limits = Limits()
        limits.maximumBodyBytes = 10
        let response = try await exchange(
            limits: limits, block: [(":method", "POST"), (":scheme", "https"), (":path", "/x")], body: Data(repeating: 0x61, count: 11))
        #expect(response.status == 413)
    }

    @Test("A body of exactly the bound is served")
    func bodyAtTheBound() async throws {
        var limits = Limits()
        limits.maximumBodyBytes = 10
        let response = try await exchange(
            limits: limits, block: [(":method", "POST"), (":scheme", "https"), (":path", "/x")], body: Data(repeating: 0x61, count: 10))
        #expect(response.status == 200)
    }

    // MARK: Helpers

    private func outcome(of c: Case) async throws -> Outcome {
        Outcome(try await exchange(limits: Limits(), block: c.block, body: c.body, trailers: c.trailers))
    }

    private func exchange(
        limits: Limits, block: [(String, String)], body: Data?, trailers: [(String, String)]? = nil, keepOpen: Bool = false,
        awaitReset: Bool = false
    ) async throws -> H2Response {
        let material = try TestTLS()
        defer { material.cleanUp() }
        let running = try await startServer(limits: limits, tls: material.files)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await H2Client.connect(
            to: running.address, group: group, tls: try material.clientContext(applicationProtocols: ["h2"]), lenient: true)
        let response = try await client.send(block: block, body: body, trailers: trailers, leaveOpen: keepOpen, awaitReset: awaitReset)
        await client.close()
        try await group.shutdownGracefully()
        await running.server.shutdown()
        return response
    }
}
