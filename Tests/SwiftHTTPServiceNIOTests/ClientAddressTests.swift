import Foundation
import NIOConcurrencyHelpers
import NIOPosix
import SwiftHTTPService
import Testing
@testable import SwiftHTTPServiceNIO

/// Who the client is, behind a proxy. Every expectation is worked out by hand from one rule: forwarded information
/// is believed only from a trusted peer, and `X-Forwarded-For` is read from the right, because a client controls
/// what it writes at the left and a trusted proxy controls what it appends at the right.
@Suite("Client address", .serialized)
struct ClientAddressTests {

    private static func config(
        _ forwarding: ServiceConfiguration.Forwarding = .xForwardedFor, trusted: [String] = ["10.0.0.0/8"]
    ) throws -> ServiceConfiguration {
        try ServiceConfiguration(trustedProxies: trusted, forwarding: forwarding)
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let peer: String?
        let header: [String]
        let expected: String?
        var forwarding: ServiceConfiguration.Forwarding = .xForwardedFor
        var trusted: [String] = ["10.0.0.0/8"]
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "a trusted proxy reports one client", peer: "10.0.0.2", header: ["203.0.113.9"], expected: "203.0.113.9"),
        Case(name: "a trusted hop after the client is skipped", peer: "10.0.0.2", header: ["203.0.113.9, 10.0.0.5"], expected: "203.0.113.9"),
        Case(name: "what the client wrote at the left is not believed: the proxy's addition at the right is",
             peer: "10.0.0.2", header: ["198.51.100.1, 203.0.113.9"], expected: "203.0.113.9"),
        Case(name: "the rightmost untrusted address wins over those further left", peer: "10.0.0.2",
             header: ["203.0.113.9, 198.51.100.7, 10.0.0.5"], expected: "198.51.100.7"),
        Case(name: "several fields are one list, in order", peer: "10.0.0.2", header: ["198.51.100.1", "203.0.113.9"], expected: "203.0.113.9"),
        Case(name: "spaces and tabs around entries are ignored", peer: "10.0.0.2", header: [" \t203.0.113.9 ,10.0.0.5\t"], expected: "203.0.113.9"),
        Case(name: "if every address is a trusted proxy the leftmost is the client", peer: "10.0.0.2", header: ["10.0.0.7, 10.0.0.5"], expected: "10.0.0.7"),
        Case(name: "an untrusted peer's header is ignored", peer: "198.51.100.50", header: ["203.0.113.9"], expected: "198.51.100.50"),
        Case(name: "an untrusted peer cannot borrow trust by listing a trusted address", peer: "198.51.100.50", header: ["10.0.0.2"], expected: "198.51.100.50"),
        Case(name: "no header means the peer", peer: "10.0.0.2", header: [], expected: "10.0.0.2"),
        Case(name: "garbage at the right means the peer, not a guess", peer: "10.0.0.2", header: ["203.0.113.9, garbage"], expected: "10.0.0.2"),
        Case(name: "garbage only means the peer", peer: "10.0.0.2", header: ["garbage"], expected: "10.0.0.2"),
        Case(name: "garbage to the left of the answer is never reached", peer: "10.0.0.2", header: ["garbage, 203.0.113.9"], expected: "203.0.113.9"),
        Case(name: "an address with a port is not an address", peer: "10.0.0.2", header: ["203.0.113.9:443"], expected: "10.0.0.2"),
        Case(name: "an empty entry means the peer", peer: "10.0.0.2", header: ["203.0.113.9,,10.0.0.5"], expected: "10.0.0.2"),
        Case(name: "a prefix is not an address", peer: "10.0.0.2", header: ["203.0.113.0/24"], expected: "10.0.0.2"),
        Case(name: "20 entries are read", peer: "10.0.0.2", header: [(0..<19).map { _ in "10.0.0.9" }.joined(separator: ", ") + ", 203.0.113.9"], expected: "203.0.113.9"),
        Case(name: "only the rightmost 20 entries are read, so padding on the left cannot move the answer",
             peer: "10.0.0.2", header: [(0..<20).map { _ in "10.0.0.9" }.joined(separator: ", ") + ", 203.0.113.9"], expected: "203.0.113.9"),
        Case(name: "a client cannot pad the list to be attributed to the proxy",
             peer: "10.0.0.2", header: [String(repeating: ",", count: 200) + " 203.0.113.9"], expected: "203.0.113.9"),
        Case(name: "garbage beyond the 20 rightmost entries is never reached",
             peer: "10.0.0.2", header: ["garbage, " + (0..<19).map { _ in "10.0.0.9" }.joined(separator: ", ") + ", 203.0.113.9"], expected: "203.0.113.9"),
        Case(name: "two spellings of one address are one client", peer: "10.0.0.2", header: ["::ffff:203.0.113.9"], expected: "203.0.113.9"),
        Case(name: "an IPv6 client is written in its canonical form", peer: "10.0.0.2", header: ["2001:0DB8:0:0:0:0:0:9"], expected: "2001:db8::9"),
        Case(name: "an unknown peer cannot be trusted, so its header is not read", peer: nil, header: ["203.0.113.9"], expected: nil),
        Case(name: "an IPv6 proxy and client", peer: "fd00::2", header: ["2001:db8::9"], expected: "2001:db8::9", trusted: ["fd00::/8"]),
        Case(name: "an IPv4-mapped peer is its IPv4 self", peer: "::ffff:10.0.0.2", header: ["203.0.113.9"], expected: "203.0.113.9"),
        Case(name: "with forwarding off the header is not read, even from a trusted peer", peer: "10.0.0.2", header: ["203.0.113.9"],
             expected: "10.0.0.2", forwarding: .none),
        Case(name: "with the PROXY protocol chosen, X-Forwarded-For is not read", peer: "10.0.0.2", header: ["203.0.113.9"],
             expected: "10.0.0.2", forwarding: .proxyProtocol),
    ]

    @Test("The client is the rightmost address that is not a trusted proxy, and only a trusted peer's word counts", arguments: cases)
    func resolution(_ c: Case) throws {
        let configuration = try ServiceConfiguration(trustedProxies: c.trusted, forwarding: c.forwarding)
        #expect(ClientAddress.resolve(peer: c.peer, proxied: nil, forwardedFor: c.header, configuration: configuration) == c.expected)
    }

    @Test("With no forwarding and no trusted proxies configured at all, the client is the peer")
    func defaultsToPeer() throws {
        let configuration = try ServiceConfiguration()
        #expect(ClientAddress.resolve(peer: "203.0.113.9", proxied: nil, forwardedFor: ["1.2.3.4"], configuration: configuration) == "203.0.113.9")
    }

    @Test("An address from the PROXY protocol is the client when that is the chosen mode, and not otherwise")
    func proxiedAddress() throws {
        let protocolMode = try Self.config(.proxyProtocol)
        #expect(ClientAddress.resolve(peer: "10.0.0.2", proxied: "203.0.113.9", forwardedFor: [], configuration: protocolMode) == "203.0.113.9")
        let headerMode = try Self.config(.xForwardedFor)
        #expect(ClientAddress.resolve(peer: "10.0.0.2", proxied: "203.0.113.9", forwardedFor: [], configuration: headerMode) == "10.0.0.2")
        let off = try ServiceConfiguration()
        #expect(ClientAddress.resolve(peer: "10.0.0.2", proxied: "203.0.113.9", forwardedFor: [], configuration: off) == "10.0.0.2")
        // A PROXY-reported client from a peer that is not trusted is not believed, whatever put it there.
        #expect(ClientAddress.resolve(peer: "198.51.100.50", proxied: "203.0.113.9", forwardedFor: [], configuration: protocolMode) == "198.51.100.50")
    }

    // MARK: On the wire

    private func start(trusted: [String], forwarding: ServiceConfiguration.Forwarding, tls: TLSFiles? = nil) async throws -> (HTTPServer, BoundAddress) {
        let handler: Handler = { request in
            Response(status: .ok, body: Data("remote=\(request.remoteAddress ?? "-");peer=\(request.peerAddress ?? "-")".utf8))
        }
        let server = HTTPServer(
            configuration: try ServiceConfiguration(port: 0, tls: tls, trustedProxies: trusted, forwarding: forwarding), handler: handler)
        return (server, try await server.start())
    }

    @Test("Over HTTP/1.1 from a trusted peer the handler sees the client the proxy reported, and the peer separately")
    func http1Trusted() async throws {
        let (server, address) = try await start(trusted: ["127.0.0.0/8"], forwarding: .xForwardedFor)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        try await client.send("GET /x HTTP/1.1\r\nHost: h\r\nX-Forwarded-For: 1.1.1.1, 203.0.113.9\r\n\r\n")
        #expect(try await client.response()?.text == "remote=203.0.113.9;peer=127.0.0.1")
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("Over HTTP/1.1 from a peer that is not trusted the header is ignored")
    func http1Untrusted() async throws {
        let (server, address) = try await start(trusted: ["10.0.0.0/8"], forwarding: .xForwardedFor)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        try await client.send("GET /x HTTP/1.1\r\nHost: h\r\nX-Forwarded-For: 203.0.113.9\r\n\r\n")
        #expect(try await client.response()?.text == "remote=127.0.0.1;peer=127.0.0.1")
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("Without forwarding configured the header is never read")
    func http1Off() async throws {
        let (server, address) = try await start(trusted: [], forwarding: .none)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        try await client.send("GET /x HTTP/1.1\r\nHost: h\r\nX-Forwarded-For: 203.0.113.9\r\n\r\n")
        #expect(try await client.response()?.text == "remote=127.0.0.1;peer=127.0.0.1")
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("Over HTTP/2 the same rule applies, per request")
    func http2() async throws {
        let material = try TestTLS()
        defer { material.cleanUp() }
        for (trusted, expected) in [("127.0.0.0/8", "remote=203.0.113.9;peer=127.0.0.1"), ("10.0.0.0/8", "remote=127.0.0.1;peer=127.0.0.1")] {
            let (server, address) = try await start(trusted: [trusted], forwarding: .xForwardedFor, tls: material.files)
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let client = try await H2Client.connect(to: address, group: group, tls: try material.clientContext(applicationProtocols: ["h2"]))
            let response = try await client.request("GET", "/x", headers: [("x-forwarded-for", "1.1.1.1, 203.0.113.9")])
            #expect(response.text == expected)
            await client.close()
            try await group.shutdownGracefully()
            await server.shutdown()
        }
    }
}
