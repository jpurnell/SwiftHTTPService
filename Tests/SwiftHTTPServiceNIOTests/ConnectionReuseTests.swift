import Foundation
import NIOPosix
import SwiftHTTPService
import Testing
@testable import SwiftHTTPServiceNIO

/// Keep-alive by default, and a mode that closes the connection after each response, for clients that cannot
/// reuse one (a hook script, a phone on a poor link). HTTP/2 is a stream per request already and is unaffected.
@Suite("Connection reuse", .serialized)
struct ConnectionReuseTests {

    private func start(_ connections: ServiceConfiguration.ConnectionReuse, tls: TLSFiles? = nil, handler: @escaping Handler = ok("hi")) async throws -> (HTTPServer, BoundAddress) {
        let server = HTTPServer(configuration: try ServiceConfiguration(port: 0, tls: tls, connections: connections), handler: handler)
        return (server, try await server.start())
    }

    private let request = "GET /x HTTP/1.1\r\nHost: h\r\n\r\n"

    @Test("By default a connection is kept for the next request, and the response says nothing of closing")
    func keepAlive() async throws {
        let (server, address) = try await start(.keepAlive)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        try await client.send(request)
        let first = try #require(try await client.response())
        #expect(first.status == 200)
        #expect(first.header("Connection") == "keep-alive")
        #expect(!client.isClosed)
        // The same connection serves a second request.
        let bytesBefore = client.received.count
        try await client.send(request)
        let deadline = ContinuousClock.now + .seconds(3)
        while client.received.count == bytesBefore, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(client.received.count > bytesBefore)
        #expect(!client.isClosed)
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("In close-after-response mode the response says Connection: close and the server then closes, though the client asked to keep it")
    func closes() async throws {
        let (server, address) = try await start(.closeAfterResponse)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        try await client.send("GET /x HTTP/1.1\r\nHost: h\r\nConnection: keep-alive\r\n\r\n")
        let response = try #require(try await client.response())
        #expect(response.status == 200)
        #expect(response.text == "hi")
        #expect(response.header("Connection") == "close")
        #expect(try await client.waitUntilClosed())
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("A second request on a connection the server has closed gets no answer, and a new connection is served as before")
    func secondRequestNeedsANewConnection() async throws {
        let (server, address) = try await start(.closeAfterResponse)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let first = try await RawClient.connect(to: address, group: group)
        try await first.send(request)
        #expect(try await first.response()?.status == 200)
        #expect(try await first.waitUntilClosed())
        let answered = first.received.count
        try? await first.send(request)                                   // the peer has gone: nothing can answer
        try await Task.sleep(for: .milliseconds(100))
        #expect(first.received.count == answered)
        let second = try await RawClient.connect(to: address, group: group)
        try await second.send(request)
        #expect(try await second.response()?.text == "hi")
        await second.close()
        await first.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("A HEAD, a POST with a body, and a handler error are each answered once and then the connection closes")
    func everyKindOfRequest() async throws {
        let (server, address) = try await start(.closeAfterResponse) { request in
            if request.path == "/boom" { throw ReuseTestError() }
            return Response(status: .ok, body: Data("body".utf8))
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        for (wire, statusLine) in [
            ("HEAD /x HTTP/1.1\r\nHost: h\r\n\r\n", "HTTP/1.1 200"),
            ("POST /x HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\n\r\nabc", "HTTP/1.1 200"),
            ("GET /boom HTTP/1.1\r\nHost: h\r\n\r\n", "HTTP/1.1 500"),
        ] {
            let client = try await RawClient.connect(to: address, group: group)
            try await client.send(wire)
            #expect(try await client.waitUntilClosed())              // the server ended it, having answered
            let text = String(decoding: client.received, as: UTF8.self)
            #expect(text.hasPrefix(statusLine), "\(text.prefix(40))")
            #expect(text.lowercased().contains("connection: close"))
            await client.close()
        }
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    private struct ReuseTestError: Error {}

    @Test("HTTP/2 is unaffected: many requests share one connection, and it stays open")
    func http2Unaffected() async throws {
        let material = try TestTLS()
        defer { material.cleanUp() }
        let (server, address) = try await start(.closeAfterResponse, tls: material.files)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await H2Client.connect(to: address, group: group, tls: try material.clientContext(applicationProtocols: ["h2"]))
        for index in 0..<4 {
            let response = try await client.request("GET", "/n/\(index)")
            #expect(response.status == 200)
            #expect(response.header("connection") == nil)
        }
        #expect(client.channel.isActive)
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }
}
