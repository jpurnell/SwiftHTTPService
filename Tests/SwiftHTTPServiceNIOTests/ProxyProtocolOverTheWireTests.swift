import Foundation
import NIOCore
import NIOPosix
import SwiftHTTPService
import Testing
@testable import SwiftHTTPServiceNIO

/// The PROXY protocol on real connections: believed from a trusted peer and only from one, required from it,
/// refused from anyone else, and read before TLS.
@Suite("PROXY protocol over the wire", .serialized)
struct ProxyProtocolOverTheWireTests {

    private static let header = Array("PROXY TCP4 203.0.113.9 192.0.2.1 5555 443\r\n".utf8)
    private static let request = Array("GET /x HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n".utf8)

    private func start(
        trusted: [String] = ["127.0.0.0/8"], tls: TLSFiles? = nil, limits: Limits = Limits()
    ) async throws -> (HTTPServer, BoundAddress) {
        let handler: Handler = { request in
            Response(status: .ok, body: Data("remote=\(request.remoteAddress ?? "-");peer=\(request.peerAddress ?? "-")".utf8))
        }
        let server = HTTPServer(
            configuration: try ServiceConfiguration(port: 0, tls: tls, limits: limits, trustedProxies: trusted, forwarding: .proxyProtocol),
            handler: handler)
        return (server, try await server.start())
    }

    private func raw(_ address: BoundAddress, _ group: MultiThreadedEventLoopGroup) async throws -> RawClient {
        try await RawClient.connect(to: address, group: group)
    }

    private func send(_ client: RawClient, _ bytes: [UInt8]) async throws {
        try await client.channel.writeAndFlush(ByteBuffer(bytes: bytes)).get()
    }

    // MARK: From a trusted proxy

    @Test("A version 1 header and the request in one write: the handler sees the client the header named, and the socket's peer separately")
    func v1() async throws {
        let (server, address) = try await start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await raw(address, group)
        try await send(client, Self.header + Self.request)
        #expect(try await client.response()?.text == "remote=203.0.113.9;peer=127.0.0.1")
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("A header that arrives a few bytes at a time is read, and the request after it is served")
    func v1Fragmented() async throws {
        let (server, address) = try await start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await raw(address, group)
        let all = Self.header + Self.request
        var offset = 0
        while offset < all.count {
            let end = min(all.count, offset + 5)
            try await send(client, Array(all[offset..<end]))
            offset = end
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try await client.response()?.text == "remote=203.0.113.9;peer=127.0.0.1")
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("A version 2 header, in binary, names the client the same way")
    func v2() async throws {
        let (server, address) = try await start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await raw(address, group)
        let signature: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A, 0x00, 0x0D, 0x0A, 0x51, 0x55, 0x49, 0x54, 0x0A]
        let body: [UInt8] = [198, 51, 100, 7] + [192, 0, 2, 1] + [0x15, 0xB3, 0x01, 0xBB]
        try await send(client, signature + [0x21, 0x11, 0x00, 0x0C] + body + Self.request)
        #expect(try await client.response()?.text == "remote=198.51.100.7;peer=127.0.0.1")
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("A header that names no client (UNKNOWN, or LOCAL) leaves the peer as the client")
    func noClientNamed() async throws {
        let (server, address) = try await start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let signature: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A, 0x00, 0x0D, 0x0A, 0x51, 0x55, 0x49, 0x54, 0x0A]
        for prelude in [Array("PROXY UNKNOWN\r\n".utf8), signature + [0x20, 0x00, 0x00, 0x00]] {
            let client = try await raw(address, group)
            try await send(client, prelude + Self.request)
            #expect(try await client.response()?.text == "remote=127.0.0.1;peer=127.0.0.1")
            await client.close()
        }
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("The header is required: a trusted peer that starts with a request is closed, and nothing is written to it")
    func headerRequired() async throws {
        let (server, address) = try await start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await raw(address, group)
        try await send(client, Self.request)
        #expect(try await client.waitUntilClosed())
        #expect(client.received.isEmpty)
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("A malformed header closes the connection with nothing written, and the handler never runs", arguments: [
        "PROXY TCP4 203.0.113.9 192.0.2.1 5555\r\n", "PROXY TCP4  203.0.113.9 192.0.2.1 5555 443\r\n", "PROXY TCP4 01.2.3.4 192.0.2.1 5555 443\r\n",
        "PROXY TCP6 203.0.113.9 192.0.2.1 5555 443\r\n", "PROXY TCP4 203.0.113.9 192.0.2.1 5555 443\n", "PROXY TCP4 1.2.3.4 5.6.7.8 70000 443\r\n",
    ])
    func malformed(_ line: String) async throws {
        let (server, address) = try await start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await raw(address, group)
        try await send(client, Array(line.utf8) + Self.request)
        #expect(try await client.waitUntilClosed())
        #expect(client.received.isEmpty)
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("A header that never finishes is closed at the header timeout")
    func incompleteHeader() async throws {
        var limits = Limits()
        limits.headerReadTimeout = .milliseconds(200)
        let (server, address) = try await start(limits: limits)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await raw(address, group)
        try await send(client, Array("PROXY TCP4 203.0.113.9 192".utf8))
        #expect(try await client.waitUntilClosed(timeout: .seconds(3)))
        #expect(client.received.isEmpty)
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("A second header in the stream is not special: it is read as the HTTP it is, and refused as such")
    func secondHeader() async throws {
        let (server, address) = try await start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await raw(address, group)
        try await send(client, Self.header + Array("PROXY TCP4 1.1.1.1 192.0.2.1 5555 443\r\n".utf8) + Self.request)
        #expect(try await client.response()?.status == 400)
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    // MARK: From anyone else

    @Test("A peer that is not trusted cannot say who it is: a header from it closes the connection, written nothing")
    func untrustedHeader() async throws {
        let (server, address) = try await start(trusted: ["10.0.0.0/8"])
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        for prelude in [Self.header, Array("PROXY UNKNOWN\r\n".utf8), [0x0D, 0x0A, 0x0D, 0x0A, 0x00, 0x0D, 0x0A, 0x51, 0x55, 0x49, 0x54, 0x0A, 0x21, 0x11, 0, 12]] {
            let client = try await raw(address, group)
            try await send(client, prelude + Self.request)
            #expect(try await client.waitUntilClosed())
            #expect(client.received.isEmpty)
            await client.close()
        }
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("A peer that is not trusted and stalls partway through what could be a header is closed at the header timeout")
    func untrustedStall() async throws {
        var limits = Limits()
        limits.headerReadTimeout = .milliseconds(200)
        let (server, address) = try await start(trusted: ["10.0.0.0/8"], limits: limits)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await raw(address, group)
        try await send(client, Array("PRO".utf8))                         // still might become "PROXY ..."
        #expect(try await client.waitUntilClosed(timeout: .seconds(3)))
        #expect(client.received.isEmpty)
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("A peer that is not trusted and sends plain HTTP is served as itself, and the header deadline does not close it later")
    func untrustedPlainOutlivesTheDeadline() async throws {
        var limits = Limits()
        limits.headerReadTimeout = .milliseconds(200)
        let (server, address) = try await start(trusted: ["10.0.0.0/8"], limits: limits)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await raw(address, group)
        try await send(client, Array("GET /x HTTP/1.1\r\nHost: h\r\n\r\n".utf8))
        #expect(try await client.response()?.status == 200)
        try await Task.sleep(for: .milliseconds(500))                      // well past the header deadline
        #expect(!client.isClosed)
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("A peer that is not trusted and sends plain HTTP is served as itself")
    func untrustedPlain() async throws {
        let (server, address) = try await start(trusted: ["10.0.0.0/8"])
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await raw(address, group)
        try await send(client, Self.request)
        #expect(try await client.response()?.text == "remote=127.0.0.1;peer=127.0.0.1")
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("A peer that is not trusted and sends a request one byte at a time is not mistaken for a proxy")
    func untrustedSlowStart() async throws {
        let (server, address) = try await start(trusted: ["10.0.0.0/8"])
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await raw(address, group)
        for byte in Self.request.prefix(8) {
            try await send(client, [byte])
            try await Task.sleep(for: .milliseconds(5))
        }
        try await send(client, Array(Self.request.dropFirst(8)))
        #expect(try await client.response()?.text == "remote=127.0.0.1;peer=127.0.0.1")
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    // MARK: Before TLS

    @Test("With TLS the header comes first, before the handshake, and the client it names is what the handler sees, over HTTP/1.1 and HTTP/2")
    func beforeTLS() async throws {
        let material = try TestTLS()
        defer { material.cleanUp() }
        let (server, address) = try await start(tls: material.files)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let http1 = try await RawClient.connect(
            to: address, group: group, tls: try material.clientContext(applicationProtocols: ["http/1.1"]), prelude: Self.header)
        try await http1.channel.writeAndFlush(ByteBuffer(bytes: Self.request)).get()
        #expect(try await http1.response()?.text == "remote=203.0.113.9;peer=127.0.0.1")
        await http1.close()
        let http2 = try await H2Client.connect(
            to: address, group: group, tls: try material.clientContext(applicationProtocols: ["h2"]), prelude: Self.header)
        let response = try await http2.request("GET", "/x")
        #expect(response.text == "remote=203.0.113.9;peer=127.0.0.1")
        #expect(http2.negotiatedProtocol == "h2")
        await http2.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("With TLS, a trusted peer whose first bytes are the TLS handshake and not a header is closed, and no handshake is answered")
    func realTLSWithoutHeader() async throws {
        let material = try TestTLS()
        defer { material.cleanUp() }
        let (server, address) = try await start(tls: material.files)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group, tls: try material.clientContext())
        try? await client.send("GET /x HTTP/1.1\r\nHost: localhost\r\n\r\n")      // a write sets the client's handshake going
        let closed = try await client.waitUntilClosed()
        let completed = client.handshakeCompleted
        let heard = client.received
        #expect(closed)
        #expect(completed == false)
        #expect(heard.isEmpty, "server wrote \(heard.count) bytes: \(Array(heard.prefix(16)))")
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("With TLS, a trusted peer that opens with a TLS hello and no header is closed, and nothing is written to it")
    func tlsWithoutHeader() async throws {
        let material = try TestTLS()
        defer { material.cleanUp() }
        let (server, address) = try await start(tls: material.files)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await raw(address, group)
        // The first five octets of a TLS record carrying a handshake: type 0x16, version 3.1, a length.
        try await send(client, [0x16, 0x03, 0x01, 0x00, 0x30] + [UInt8](repeating: 0, count: 0x30))
        let closed = try await client.waitUntilClosed()
        let heard = client.received
        #expect(closed)
        #expect(heard.isEmpty, "server wrote \(heard.count) bytes: \(Array(heard.prefix(16)))")
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }
}
