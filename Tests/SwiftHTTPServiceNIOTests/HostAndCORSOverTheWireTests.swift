import Foundation
import NIOPosix
import SwiftHTTPService
import Testing
@testable import SwiftHTTPServiceNIO

/// `allowedHosts` and `cors` on real connections: HTTP/1.1 `Host`, HTTP/2 `:authority`, a preflight, a streaming response.
@Suite("Host allow-list and CORS over the wire", .serialized)
struct HostAndCORSOverTheWireTests {
    private static let origin = "https://app.example"
    private static let refusal421 = Data(#"{"code":"misdirected_request","status":421,"title":"Misdirected Request","type":"about:blank"}"#.utf8)

    private func layers() throws -> [Middleware] {
        [try allowedHosts(["api.test", "api.test:8443"]), try cors(allowedOrigins: [Self.origin])]
    }

    private func withH2<T>(handler: @escaping Handler, _ body: (H2Client) async throws -> T) async throws -> T {
        let material = try TestTLS()
        defer { material.cleanUp() }
        let server = HTTPServer(configuration: try ServiceConfiguration(port: 0, tls: material.files), handler: handler)
        let address = try await server.start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let result: T
        do {
            let client = try await H2Client.connect(to: address, group: group, tls: try material.clientContext(applicationProtocols: ["h2"]))
            result = try await body(client)
            await client.close()
        } catch {
            try? await group.shutdownGracefully()
            await server.shutdown()
            throw error
        }
        try await group.shutdownGracefully()
        await server.shutdown()
        return result
    }

    @Test("HTTP/1.1: the Host header is checked; a listed host and a stranger get 200 and 421 on one connection")
    func http1Host() async throws {
        let running = try await startServer(handler: wrap(ok("hello"), with: try layers()))
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: running.address, group: group)
        try await client.send("GET /x HTTP/1.1\r\nHost: API.test:8443\r\n\r\n")
        let good = try #require(try await client.response())
        #expect(good.status == 200)
        #expect(good.body == Data("hello".utf8))
        let fresh = try await RawClient.connect(to: running.address, group: group)
        try await fresh.send("GET /x HTTP/1.1\r\nHost: 127.0.0.1:8443\r\n\r\n")
        let bad = try #require(try await fresh.response())
        #expect(bad.status == 421)
        #expect(bad.body == Self.refusal421)
        #expect(bad.values("content-type") == ["application/problem+json"])
        await client.close()
        await fresh.close()
        try await group.shutdownGracefully()
        await running.server.shutdown()
    }

    @Test("HTTP/2: :authority is checked the same way")
    func http2Authority() async throws {
        try await withH2(handler: wrap(ok("hello"), with: try layers())) { client in
            let good = try await client.request("GET", "/x", authority: "api.test:8443")
            #expect(good.status == 200)
            #expect(good.text == "hello")
            let bad = try await client.request("GET", "/x", authority: "evil.test")
            #expect(bad.status == 421)
            #expect(bad.body == Self.refusal421)
            let wrongPort = try await client.request("GET", "/x", authority: "api.test:9")
            #expect(wrongPort.status == 421)
        }
    }

    @Test("HTTP/1.1: a preflight is answered by the middleware, and a stranger's origin is refused 403")
    func http1Preflight() async throws {
        let running = try await startServer(handler: wrap(ok("hello"), with: try layers()))
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: running.address, group: group)
        try await client.send("OPTIONS /anything HTTP/1.1\r\nHost: api.test\r\nOrigin: \(Self.origin)\r\n\r\n")
        let preflight = try #require(try await client.response())
        #expect(preflight.status == 204)
        #expect(preflight.values("access-control-allow-origin") == [Self.origin])
        #expect(preflight.values("access-control-allow-methods") == ["POST"])
        #expect(preflight.values("access-control-allow-headers") == ["Authorization, Content-Type"])
        #expect(preflight.values("vary") == ["Origin"])
        let second = try await RawClient.connect(to: running.address, group: group)
        try await second.send("GET /x HTTP/1.1\r\nHost: api.test\r\nOrigin: https://evil.example\r\n\r\n")
        let stranger = try #require(try await second.response())
        #expect(stranger.status == 403)
        #expect(stranger.values("access-control-allow-origin").isEmpty)
        #expect(stranger.values("vary") == ["Origin"])
        await second.close()
        await client.close()
        try await group.shutdownGracefully()
        await running.server.shutdown()
    }

    private static let streamer: Handler = { _ in
        .streaming(status: .ok) { writer in try await writer.write(Data("chunk".utf8)) }
    }

    @Test("HTTP/1.1: a streaming response carries Access-Control-Allow-Origin and Vary in its head")
    func http1Streaming() async throws {
        let running = try await startServer(handler: wrap(Self.streamer, with: try layers()))
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: running.address, group: group)
        try await client.send("GET /x HTTP/1.1\r\nHost: api.test\r\nOrigin: \(Self.origin)\r\n\r\n")
        #expect(try await client.wait { ChunkedBody($0.splitResponse?.body ?? Data()).complete })
        let split = try #require(client.splitResponse)
        let head = split.head.lowercased()
        #expect(head.hasPrefix("http/1.1 200"))
        #expect(head.contains("transfer-encoding: chunked"))
        #expect(head.contains("access-control-allow-origin: \(Self.origin)"))
        #expect(head.contains("vary: origin"))
        #expect(ChunkedBody(split.body).chunks == [Data("chunk".utf8)])
        await client.close()
        try await group.shutdownGracefully()
        await running.server.shutdown()
    }

    @Test("HTTP/2: a streaming response carries the headers, and a preflight is a 204")
    func http2StreamingAndPreflight() async throws {
        try await withH2(handler: wrap(Self.streamer, with: try layers())) { client in
            let streamed = try await client.request("GET", "/x", authority: "api.test", headers: [("origin", Self.origin)])
            #expect(streamed.status == 200)
            #expect(streamed.text == "chunk")
            #expect(streamed.header("access-control-allow-origin") == Self.origin)
            #expect(streamed.header("vary") == "Origin")
            let preflight = try await client.request("OPTIONS", "/x", authority: "api.test", headers: [("origin", Self.origin)])
            #expect(preflight.status == 204)
            #expect(preflight.header("access-control-allow-methods") == "POST")
        }
    }
}
