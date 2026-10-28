import Foundation
import HTTPTypes
import NIOPosix
import SwiftHTTPService
import SwiftTLSKit
import SwiftTLSKitTestSupport
import Testing
@testable import SwiftHTTPServiceNIO

/// HTTP/2 over real TLS on loopback. A handler cannot tell which version carried its request, so the same
/// handlers serve both; what these tests pin is that the same request gets the same answer, and that the
/// version is only ever the one the configuration allowed.
@Suite("HTTP/2", .serialized)
struct HTTP2Tests {

    private func withGroup<T>(_ body: (MultiThreadedEventLoopGroup) async throws -> T) async throws -> T {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let result: T
        do { result = try await body(group) } catch {
            try? await group.shutdownGracefully()
            throw error
        }
        try await group.shutdownGracefully()
        return result
    }

    // MARK: Negotiation

    @Test("A client that offers h2 and http/1.1 gets h2 by default")
    func negotiatesH2() async throws {
        let material = try TestTLS()
        defer { material.cleanUp() }
        let running = try await startServer(tls: material.files)
        try await withGroup { group in
            let client = try await H2Client.connect(
                to: running.address, group: group, tls: try material.clientContext(applicationProtocols: ["h2", "http/1.1"]))
            let response = try await client.request("GET", "/x")
            #expect(client.negotiatedProtocol == "h2")
            #expect(response.status == 200)
            await client.close()
        }
        await running.server.shutdown()
    }

    @Test("Narrowed to HTTP/1.1, the same client is given http/1.1 and not h2")
    func narrowedToHTTP1() async throws {
        let material = try TestTLS()
        defer { material.cleanUp() }
        let running = try await startServer(tls: material.files, protocols: .http1)
        try await withGroup { group in
            let client = try await RawClient.connect(
                to: running.address, group: group, tls: try material.clientContext(applicationProtocols: ["h2", "http/1.1"]))
            try await client.send("GET /x HTTP/1.1\r\nHost: localhost\r\n\r\n")
            #expect(try await client.response()?.status == 200)
            #expect(client.negotiatedProtocol == "http/1.1")
            await client.close()
        }
        await running.server.shutdown()
    }

    @Test("An HTTP/1.1-only client is still served over HTTP/1.1 when HTTP/2 is on")
    func http1ClientStillServed() async throws {
        let material = try TestTLS()
        defer { material.cleanUp() }
        let running = try await startServer(tls: material.files, handler: ok("one point one"))
        try await withGroup { group in
            let client = try await RawClient.connect(to: running.address, group: group, tls: try material.clientContext())
            try await client.send("GET /x HTTP/1.1\r\nHost: localhost\r\n\r\n")
            let response = try #require(try await client.response())
            #expect(response.text == "one point one")
            #expect(client.negotiatedProtocol == "http/1.1")
            await client.close()
        }
        await running.server.shutdown()
    }

    // MARK: Requests and responses

    @Test("A GET is answered with the handler's status, body, Content-Length and a Date, and no Connection field")
    func getRoundTrip() async throws {
        let material = try TestTLS()
        defer { material.cleanUp() }
        let running = try await startServer(tls: material.files) { request in
            Response(status: .ok, body: Data("path=\(request.path) method=\(request.method.rawValue)".utf8))
        }
        try await withGroup { group in
            let client = try await H2Client.connect(
                to: running.address, group: group, tls: try material.clientContext(applicationProtocols: ["h2"]))
            let response = try await client.request("GET", "/v1/things")
            #expect(response.status == 200)
            #expect(response.text == "path=/v1/things method=GET")
            #expect(response.header("content-length") == "26")   // the 26 bytes of the body above, counted by hand
            // An IMF-fixdate (RFC 9110 section 5.6.7): day name, date, time, and the literal GMT.
            let date = try #require(response.header("date"))
            _ = try #require(date.range(of: #"^[A-Z][a-z]{2}, \d{2} [A-Z][a-z]{2} \d{4} \d{2}:\d{2}:\d{2} GMT$"#, options: .regularExpression))
            #expect(response.header("connection") == nil)        // connection-specific fields are forbidden in HTTP/2
            #expect(response.ended)
            await client.close()
        }
        await running.server.shutdown()
    }

    @Test("A POST body arrives whole and is echoed")
    func postRoundTrip() async throws {
        let material = try TestTLS()
        defer { material.cleanUp() }
        let running = try await startServer(tls: material.files) { request in
            Response(status: .created, body: request.body)
        }
        try await withGroup { group in
            let client = try await H2Client.connect(
                to: running.address, group: group, tls: try material.clientContext(applicationProtocols: ["h2"]))
            let response = try await client.request("POST", "/v1/things", body: Data("{\"a\":1}".utf8))
            #expect(response.status == 201)
            #expect(response.text == "{\"a\":1}")
            await client.close()
        }
        await running.server.shutdown()
    }

    @Test("A HEAD gets the status and fields and no body")
    func headHasNoBody() async throws {
        let material = try TestTLS()
        defer { material.cleanUp() }
        let running = try await startServer(tls: material.files, handler: ok("twelve bytes"))
        try await withGroup { group in
            let client = try await H2Client.connect(
                to: running.address, group: group, tls: try material.clientContext(applicationProtocols: ["h2"]))
            let response = try await client.request("HEAD", "/x")
            #expect(response.status == 200)
            #expect(response.body.isEmpty)
            #expect(response.header("content-length") == "12")
            await client.close()
        }
        await running.server.shutdown()
    }

    @Test("Several requests on one connection each get their own answer")
    func manyStreams() async throws {
        let material = try TestTLS()
        defer { material.cleanUp() }
        let running = try await startServer(tls: material.files) { request in
            Response(status: .ok, body: Data(request.path.utf8))
        }
        try await withGroup { group in
            let client = try await H2Client.connect(
                to: running.address, group: group, tls: try material.clientContext(applicationProtocols: ["h2"]))
            for index in 0..<5 {
                let response = try await client.request("GET", "/n/\(index)")
                #expect(response.text == "/n/\(index)")
            }
            await client.close()
        }
        await running.server.shutdown()
    }

    @Test("A handler that throws is answered with the fixed 500, and the error's text is never sent")
    func handlerThrows() async throws {
        struct Secret: Error, CustomStringConvertible { var description: String { "the database password" } }
        let material = try TestTLS()
        defer { material.cleanUp() }
        let running = try await startServer(tls: material.files) { _ in throw Secret() }
        try await withGroup { group in
            let client = try await H2Client.connect(
                to: running.address, group: group, tls: try material.clientContext(applicationProtocols: ["h2"]))
            let response = try await client.request("GET", "/x")
            #expect(response.status == 500)
            #expect(response.body == Refusal.internalError.body)
            #expect(response.header("content-type") == "application/problem+json")
            #expect(!response.text.contains("password"))
            await client.close()
        }
        await running.server.shutdown()
    }

    // MARK: The handshake

    // That a finished handshake cancels the deadline is HTTP2LimitsTests.busyConnectionIsKept: a stream held
    // open for three idle timeouts survives, which it would not if the deadline were still armed.
    @Test("A connection to a TLS server that never starts a handshake is closed at the idle timeout")
    func stalledHandshakeIsClosed() async throws {
        let material = try TestTLS()
        defer { material.cleanUp() }
        var limits = Limits()
        limits.idleTimeout = .milliseconds(200)
        let running = try await startServer(limits: limits, tls: material.files)
        try await withGroup { group in
            let client = try await RawClient.connect(to: running.address, group: group)   // TCP, and no ClientHello
            #expect(try await client.waitUntilClosed(timeout: .seconds(3)))
            #expect(client.received.isEmpty)
        }
        await running.server.shutdown()
    }
}
