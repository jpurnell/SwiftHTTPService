import Foundation
import NIOConcurrencyHelpers
import NIOPosix
import SwiftHTTPService
import Testing
@testable import SwiftHTTPServiceNIO

/// The transport tells a handler which version of HTTP carried its request.
@Suite("Request version over the wire", .serialized)
struct RequestVersionOverTheWireTests {

    private func capturing() -> (Handler, NIOLockedValueBox<[HTTPProtocolVersion]>) {
        let seen = NIOLockedValueBox<[HTTPProtocolVersion]>([])
        let handler: Handler = { request in
            seen.withLockedValue { $0.append(request.httpVersion) }
            return Response(status: .ok)
        }
        return (handler, seen)
    }

    @Test("A request line of HTTP/1.1 is seen as HTTP/1.1, and HTTP/1.0 as HTTP/1.0")
    func http1Versions() async throws {
        let (handler, seen) = capturing()
        let running = try await startServer(handler: handler)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        for line in ["GET /x HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n", "GET /x HTTP/1.0\r\n\r\n"] {
            let client = try await RawClient.connect(to: running.address, group: group)
            try await client.send(line)
            #expect(try await client.response()?.status == 200)
            await client.close()
        }
        try await group.shutdownGracefully()
        await running.server.shutdown()
        #expect(seen.withLockedValue { $0 } == [.http1_1, .http1_0])
    }

    @Test("A request over HTTP/2 is seen as HTTP/2")
    func http2Version() async throws {
        let (handler, seen) = capturing()
        let material = try TestTLS()
        defer { material.cleanUp() }
        let running = try await startServer(tls: material.files, handler: handler)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await H2Client.connect(
            to: running.address, group: group, tls: try material.clientContext(applicationProtocols: ["h2"]))
        #expect(try await client.request("GET", "/x").status == 200)
        await client.close()
        try await group.shutdownGracefully()
        await running.server.shutdown()
        #expect(seen.withLockedValue { $0 } == [.http2])
    }

    @Test("Over TLS with HTTP/1.1 negotiated it is HTTP/1.1")
    func tlsHTTP1() async throws {
        let (handler, seen) = capturing()
        let material = try TestTLS()
        defer { material.cleanUp() }
        let running = try await startServer(tls: material.files, protocols: .http1, handler: handler)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await RawClient.connect(to: running.address, group: group, tls: try material.clientContext())
        try await client.send("GET /x HTTP/1.1\r\nHost: localhost\r\n\r\n")
        #expect(try await client.response()?.status == 200)
        await client.close()
        try await group.shutdownGracefully()
        await running.server.shutdown()
        #expect(seen.withLockedValue { $0 } == [.http1_1])
    }
}
