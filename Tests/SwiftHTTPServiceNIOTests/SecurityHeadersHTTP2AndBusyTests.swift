import Foundation
import HTTPTypes
import NIOPosix
import SwiftHTTPService
import SwiftTLSKit
import SwiftTLSKitTestSupport
import Testing
@testable import SwiftHTTPServiceNIO

/// The same promise as `SecurityHeadersEveryPathTests`, for the paths that need a real TLS connection: HTTP/2 responses
/// (where HSTS is always present, since HTTP/2 only runs over TLS) and the busy refusals, which are written before any
/// handler or router is involved, in HTTP/1.1 and in HTTP/2, over plaintext and over TLS.
@Suite("Security headers over HTTP/2 and on busy refusals", .serialized)
struct SecurityHeadersHTTP2AndBusyTests {

    private static let jsonCSP = "default-src 'none'; frame-ancestors 'none'"

    // MARK: What a response must carry

    private static func expectSafe(
        _ response: H2Response, csp: Bool, exactCacheControl: String? = nil, _ label: String
    ) {
        func values(_ name: String) -> [String] { response.headers.filter { $0.name == name }.map(\.value) }
        #expect(values("x-content-type-options") == ["nosniff"], "\(label): nosniff")
        #expect(values("cache-control").count == 1, "\(label): Cache-Control \(values("cache-control"))")
        if let exactCacheControl { #expect(values("cache-control") == [exactCacheControl], "\(label): Cache-Control") }
        #expect(values("cache-control").first?.contains("no-store") == true, "\(label): no-store")
        #expect(values("referrer-policy") == ["no-referrer"], "\(label): Referrer-Policy")
        #expect(values("x-frame-options") == ["DENY"], "\(label): X-Frame-Options")
        #expect(values("content-security-policy") == (csp ? [jsonCSP] : []), "\(label): CSP")
        #expect(values("strict-transport-security") == ["max-age=604800"], "\(label): HSTS (HTTP/2 is always TLS)")
        #expect(values("server").isEmpty && values("x-powered-by").isEmpty, "\(label): names the software")
        for (name, value) in response.headers { #expect(!value.contains("NIO"), "\(label): \(name) says \(value)") }
    }

    private static func expectSafe(_ response: WireResponse, overTLS: Bool, _ label: String) {
        #expect(response.values("X-Content-Type-Options") == ["nosniff"], "\(label): nosniff")
        #expect(response.values("Cache-Control").count == 1, "\(label): Cache-Control")
        #expect(response.values("Cache-Control").first?.contains("no-store") == true, "\(label): no-store")
        #expect(response.values("Referrer-Policy") == ["no-referrer"], "\(label): Referrer-Policy")
        #expect(response.values("X-Frame-Options") == ["DENY"], "\(label): X-Frame-Options")
        #expect(response.values("Content-Security-Policy") == [jsonCSP], "\(label): CSP")
        #expect(response.values("Strict-Transport-Security") == (overTLS ? ["max-age=604800"] : []), "\(label): HSTS")
        #expect(response.values("Retry-After") == ["1"], "\(label): the refusal's own Retry-After is kept")
    }

    // MARK: HTTP/2

    @Test("Over HTTP/2 a JSON 200, a router 404, a thrown-error 500, a stream and an event stream each carry the headers, with HSTS")
    func http2Paths() async throws {
        struct Boom: Error {}
        let material = try TestTLS()
        defer { material.cleanUp() }
        var router = Router()
        try router.get("/json") { _ in try Response.json(["a": 1]) }
        try router.get("/boom") { _ in throw Boom() }
        try router.get("/stream") { _ in .streaming(status: .ok) { writer in try await writer.write(Data("s".utf8)) } }
        try router.get("/events") { _ in Response.eventStream { writer in try await writer.send(data: "hello") } }
        let server = HTTPServer(configuration: try ServiceConfiguration(port: 0, tls: material.files), router: router)
        let address = try await server.start()
        try await withClientGroup { group in
            let client = try await H2Client.connect(to: address, group: group, tls: try material.clientContext(applicationProtocols: ["h2"]))
            let json = try await client.request("GET", "/json")
            #expect(client.negotiatedProtocol == "h2")
            #expect(json.status == 200)
            Self.expectSafe(json, csp: true, "h2 json")

            let missing = try await client.request("GET", "/missing")
            #expect(missing.status == 404)
            Self.expectSafe(missing, csp: true, "h2 404")

            let boom = try await client.request("GET", "/boom")
            #expect(boom.status == 500)
            Self.expectSafe(boom, csp: true, "h2 500")

            let stream = try await client.request("GET", "/stream")
            #expect(stream.status == 200)
            Self.expectSafe(stream, csp: false, "h2 stream")

            let watched = try await client.open("GET", "/events")
            _ = try await watched.wait { $0.status != nil }
            Self.expectSafe(watched.response, csp: false, exactCacheControl: "no-store", "h2 event stream head")
            await watched.reset()
            await client.close()
        }
        await server.shutdown()
    }

    // MARK: Busy refusals

    @Test("A busy refusal over plaintext HTTP/1.1 carries the headers, and no HSTS")
    func busyPlaintext() async throws {
        let running = try await startServer(limits: Limits(maximumConnections: 1))
        try await withClientGroup { group in
            let held = try await RawClient.connect(to: running.address, group: group)
            try await held.send("GET /x HTTP/1.1\r\nHost: localhost\r\n\r\n")
            #expect(try await held.response()?.status == 200)

            let refused = try await RawClient.connect(to: running.address, group: group)
            let answer = try #require(try await refused.response())
            #expect(answer.status == 503)
            Self.expectSafe(answer, overTLS: false, "busy plaintext")
            await held.close()
        }
        await running.server.shutdown()
    }

    @Test("A busy refusal over TLS, in HTTP/1.1 and in h2, carries the headers and HSTS")
    func busyOverTLS() async throws {
        let material = try TestTLS()
        defer { material.cleanUp() }
        let server = HTTPServer(
            configuration: try ServiceConfiguration(port: 0, tls: material.files, limits: Limits(maximumConnections: 1)), handler: ok())
        let address = try await server.start()
        try await withClientGroup { group in
            let held = try await RawClient.connect(to: address, group: group, tls: try material.clientContext())
            try await held.send("GET /x HTTP/1.1\r\nHost: localhost\r\n\r\n")
            #expect(try await held.response()?.status == 200)

            let refused = try await RawClient.connect(to: address, group: group, tls: try material.clientContext(applicationProtocols: ["http/1.1"]))
            let answer = try #require(try await refused.response())
            #expect(answer.status == 503)
            Self.expectSafe(answer, overTLS: true, "busy TLS http/1.1")

            let h2 = try await H2Client.connect(to: address, group: group, tls: try material.clientContext(applicationProtocols: ["h2", "http/1.1"]))
            let response = try await h2.request("GET", "/x")
            #expect(response.status == 503)
            Self.expectSafe(response, csp: true, "busy h2")
            #expect(response.header("retry-after") == "1")
            await h2.close()
            await held.close()
        }
        await server.shutdown()
    }
}
