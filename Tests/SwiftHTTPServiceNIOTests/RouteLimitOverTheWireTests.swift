import Foundation
import NIOConcurrencyHelpers
import NIOPosix
import SwiftHTTPService
import Testing
@testable import SwiftHTTPServiceNIO

/// A route's own body bound, on a real connection, over both versions of HTTP.
@Suite("Route limits over the wire", .serialized)
struct RouteLimitOverTheWireTests {

    private static func router() throws -> Router {
        var router = Router()
        let echo: Handler = { request in Response(status: .ok, body: Data(String(request.body.count).utf8)) }
        try router.post("/small", maximumBodyBytes: 10, echo)          // lower than the server's 100
        try router.post("/big", maximumBodyBytes: 1_000, echo)         // higher than the server's 100
        try router.post("/default", echo)                              // the server's own bound
        return router
    }

    private static func limits() -> Limits {
        var limits = Limits()
        limits.maximumBodyBytes = 100
        return limits
    }

    private func start(tls: TLSFiles? = nil) async throws -> (HTTPServer, BoundAddress) {
        let server = HTTPServer(configuration: try ServiceConfiguration(port: 0, tls: tls, limits: Self.limits()), router: try Self.router())
        return (server, try await server.start())
    }

    private func post(_ path: String, bytes: Int, to address: BoundAddress, group: MultiThreadedEventLoopGroup) async throws -> WireResponse {
        let client = try await RawClient.connect(to: address, group: group)
        let body = String(repeating: "a", count: bytes)
        try await client.send("POST \(path) HTTP/1.1\r\nHost: h\r\nContent-Length: \(bytes)\r\nConnection: close\r\n\r\n\(body)")
        let response = try #require(try await client.response())
        await client.close()
        return response
    }

    @Test("A route can lower the bound: a body of 11 to a route bounded at 10 is refused, 10 is served")
    func lowered() async throws {
        let (server, address) = try await start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        #expect(try await post("/small", bytes: 10, to: address, group: group).text == "10")
        #expect(try await post("/small", bytes: 11, to: address, group: group).status == 413)
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("A route can raise the bound: 500 bytes to a route bounded at 1000 are served though the server's is 100")
    func raised() async throws {
        let (server, address) = try await start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        #expect(try await post("/big", bytes: 500, to: address, group: group).text == "500")
        #expect(try await post("/big", bytes: 1_000, to: address, group: group).text == "1000")
        #expect(try await post("/big", bytes: 1_001, to: address, group: group).status == 413)
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("A route without an override takes the server's bound, and so do paths that do not exist")
    func global() async throws {
        let (server, address) = try await start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        #expect(try await post("/default", bytes: 100, to: address, group: group).text == "100")
        #expect(try await post("/default", bytes: 101, to: address, group: group).status == 413)
        #expect(try await post("/nowhere", bytes: 101, to: address, group: group).status == 413)    // refused before routing could say 404
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("The bound applies to a chunked body too, which declares no length")
    func chunked() async throws {
        let (server, address) = try await start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        func chunkedPost(_ path: String, bytes: Int) async throws -> WireResponse {
            let client = try await RawClient.connect(to: address, group: group)
            let chunk = String(repeating: "a", count: bytes)
            try await client.send("POST \(path) HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n\(String(bytes, radix: 16))\r\n\(chunk)\r\n0\r\n\r\n")
            let response = try #require(try await client.response())
            await client.close()
            return response
        }
        #expect(try await chunkedPost("/small", bytes: 10).text == "10")
        #expect(try await chunkedPost("/small", bytes: 11).status == 413)
        #expect(try await chunkedPost("/big", bytes: 500).text == "500")
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("A body past the route's bound is refused before it is read: the refusal comes after the head alone")
    func refusedUnread() async throws {
        let (server, address) = try await start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: address, group: group)
        try await client.send("POST /small HTTP/1.1\r\nHost: h\r\nContent-Length: 11\r\n\r\n")          // no body sent
        #expect(try await client.response()?.status == 413)
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("Over HTTP/2 the same route bounds apply")
    func http2() async throws {
        let material = try TestTLS()
        defer { material.cleanUp() }
        let (server, address) = try await start(tls: material.files)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await H2Client.connect(to: address, group: group, tls: try material.clientContext(applicationProtocols: ["h2"]))
        func post(_ path: String, bytes: Int) async throws -> H2Response {
            try await client.request("POST", path, body: Data(repeating: 0x61, count: bytes))
        }
        #expect(try await post("/small", bytes: 10).text == "10")
        #expect(try await post("/small", bytes: 11).status == 413)
        #expect(try await post("/big", bytes: 500).text == "500")
        #expect(try await post("/big", bytes: 1_001).status == 413)
        #expect(try await post("/default", bytes: 101).status == 413)
        await client.close()
        try await group.shutdownGracefully()
        await server.shutdown()
    }

    @Test("The router initialiser wraps the router in the given middleware and sends its bounds to the transport")
    func routerInitialiser() async throws {
        let seen = NIOLockedValueBox<[String]>([])
        let layer: Middleware = { request, next in
            seen.withLockedValue { $0.append(request.path) }
            return try await next(request)
        }
        let server = HTTPServer(
            configuration: try ServiceConfiguration(port: 0, limits: Self.limits()), router: try Self.router(), middleware: [layer])
        let address = try await server.start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        #expect(try await post("/big", bytes: 500, to: address, group: group).text == "500")
        try await group.shutdownGracefully()
        await server.shutdown()
        #expect(seen.withLockedValue { $0 } == ["/big"])
    }
}
