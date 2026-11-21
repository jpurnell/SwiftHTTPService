import Foundation
import HTTPTypes
import Testing
import SwiftHTTPService
@testable import SwiftHTTPServiceNIO

/// Every response the server writes carries the safe headers, whatever wrote it: a handler, the router, a middleware,
/// a thrown error, a stream, or the transport's own refusal. Expected values are the literals of
/// `project/plans/proposals/SecurityHeaders.md` section 4.1. HTTP/1.1, on the testing channel, so the bytes are the wire's.
@Suite("Security headers on every response path (HTTP/1.1)")
struct SecurityHeadersEveryPathTests {

    private static let jsonCSP = "default-src 'none'; frame-ancestors 'none'"

    // MARK: What one response must carry

    /// - Parameters:
    ///   - csp: Whether the response is JSON or empty, so it gets the API CSP.
    ///   - exactCacheControl: A value the response must have exactly (a stream's own `no-store`); otherwise any value with the token.
    private static func expectSafe(
        _ response: WireResponse, overTLS: Bool, csp: Bool, exactCacheControl: String? = nil, _ label: String
    ) {
        #expect(response.values("X-Content-Type-Options") == ["nosniff"], "\(label): nosniff")
        let cache = response.values("Cache-Control")
        #expect(cache.count == 1, "\(label): Cache-Control appears \(cache.count) times")
        if let exactCacheControl {
            #expect(cache == [exactCacheControl], "\(label): Cache-Control")
        } else {
            #expect(cache.first?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.contains("no-store") == true,
                    "\(label): Cache-Control \(cache)")
        }
        #expect(response.values("Referrer-Policy") == ["no-referrer"], "\(label): Referrer-Policy")
        #expect(response.values("X-Frame-Options") == ["DENY"], "\(label): X-Frame-Options")
        #expect(response.values("Content-Security-Policy") == (csp ? [jsonCSP] : []), "\(label): CSP")
        #expect(response.values("Strict-Transport-Security") == (overTLS ? ["max-age=604800"] : []), "\(label): HSTS")
        // Nothing names the software: no Server, no X-Powered-By, and no value that says NIO.
        #expect(response.values("Server").isEmpty, "\(label): Server")
        #expect(response.values("X-Powered-By").isEmpty, "\(label): X-Powered-By")
        for (name, value) in response.headers {
            #expect(!value.contains("NIO"), "\(label): \(name) says \(value)")
        }
    }

    // MARK: Driving a handler

    private static let tlsFiles = TLSFiles(certificateChainPath: "/nonexistent/chain.pem", privateKeyPath: "/nonexistent/key.pem")

    private static func configuration(overTLS: Bool) throws -> ServiceConfiguration {
        try ServiceConfiguration(port: 0, tls: overTLS ? tlsFiles : nil)
    }

    private static func get(_ path: String, method: String = "GET") -> String {
        "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\n\r\n"
    }

    /// One request through the production pipeline, and the response it got.
    private static func respond(
        to request: String, overTLS: Bool = false, handler: @escaping Handler
    ) async throws -> WireResponse {
        let harness = try await PipelineHarness(configuration: try configuration(overTLS: overTLS), handler: handler)
        try await harness.send(request)
        let response = try #require(try await harness.readResponse())
        await harness.finish()
        return response
    }

    /// A HEAD response has a Content-Length and no body, so it is read to the end of its head.
    private static func respondToHead(_ path: String, overTLS: Bool, handler: @escaping Handler) async throws -> WireResponse {
        let harness = try await PipelineHarness(configuration: try configuration(overTLS: overTLS), handler: handler)
        try await harness.send(get(path, method: "HEAD"))
        var pending = Data()
        let deadline = ContinuousClock.now + .seconds(5)
        let terminator = Data("\r\n\r\n".utf8)
        while ContinuousClock.now < deadline, pending.range(of: terminator) == nil {
            pending.append(try await harness.drainOutbound())
            try await Task.sleep(for: .milliseconds(2))
        }
        let end = try #require(pending.range(of: terminator))
        let text = String(decoding: pending[pending.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        let statusLine = lines.removeFirst()
        let headers = lines.compactMap { line -> (name: String, value: String)? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        await harness.finish()
        return WireResponse(statusLine: statusLine, headers: headers, body: Data())
    }

    private static func router(_ build: (inout Router) throws -> Void) throws -> Router {
        var router = Router()
        try build(&router)
        return router
    }

    // MARK: Handler results

    @Test("A JSON 200, a problem, a 204, a 304 and a handler's HTML page each carry the headers, over plaintext and over TLS")
    func handlerResults() async throws {
        for overTLS in [false, true] {
            let tag = overTLS ? "TLS" : "plain"
            let json = try await Self.respond(to: Self.get("/x"), overTLS: overTLS) { _ in try Response.json(["a": 1]) }
            Self.expectSafe(json, overTLS: overTLS, csp: true, "\(tag) json")

            let problem = try await Self.respond(to: Self.get("/x"), overTLS: overTLS) { _ in
                try Response.problem(Problem(status: .conflict, code: "conflict", detail: "x"))
            }
            Self.expectSafe(problem, overTLS: overTLS, csp: true, "\(tag) problem")

            let empty = try await Self.respond(to: Self.get("/x"), overTLS: overTLS) { _ in .empty(.noContent) }
            Self.expectSafe(empty, overTLS: overTLS, csp: true, "\(tag) 204")

            let notModified = try await Self.respond(to: Self.get("/x"), overTLS: overTLS) { _ in .notModified(etag: "\"v1\"") }
            Self.expectSafe(notModified, overTLS: overTLS, csp: true, "\(tag) 304")
            #expect(notModified.header("ETag") == "\"v1\"")

            let page = try await Self.respond(to: Self.get("/x"), overTLS: overTLS) { _ in
                var headers = HTTPFields()
                headers[.contentType] = "text/html"
                return Response(status: .ok, headers: headers, body: Data("<p>hi</p>".utf8))
            }
            Self.expectSafe(page, overTLS: overTLS, csp: false, "\(tag) html")
        }
    }

    @Test("A HEAD request's response carries the headers: they describe the would-be GET")
    func head() async throws {
        let response = try await Self.respondToHead("/x", overTLS: false) { _ in try Response.json(["a": 1]) }
        #expect(response.status == 200)
        #expect(response.body.isEmpty, "a HEAD response has no body")
        Self.expectSafe(response, overTLS: false, csp: true, "HEAD")
    }

    @Test("A handler's own Cache-Control survives, once, and the other defaults are still added")
    func handlerCacheControlSurvives() async throws {
        let response = try await Self.respond(to: Self.get("/x")) { _ in
            try Response.json(["a": 1]).setting(.cacheControl, to: "private, max-age=60")
        }
        #expect(response.values("Cache-Control") == ["private, max-age=60"])
        #expect(response.values("X-Content-Type-Options") == ["nosniff"])
    }

    // MARK: Router, middleware, errors

    @Test("The router's own 404 and 405, and a custom notFound that returns a bare Response, carry the headers")
    func routerResponses() async throws {
        var router = try Self.router { try $0.get("/only") { _ in try Response.json(["a": 1]) } }
        let handler = router.handler
        let notFound = try await Self.respond(to: Self.get("/missing"), handler: handler)
        #expect(notFound.status == 404)
        Self.expectSafe(notFound, overTLS: false, csp: true, "router 404")

        let notAllowed = try await Self.respond(to: Self.get("/only", method: "DELETE"), handler: handler)
        #expect(notAllowed.status == 405)
        Self.expectSafe(notAllowed, overTLS: false, csp: true, "router 405")

        router.notFound = { _ in Response(status: .notFound) }
        router.methodNotAllowed = { _, _ in Response(status: .methodNotAllowed) }
        let custom404 = try await Self.respond(to: Self.get("/missing"), handler: router.handler)
        Self.expectSafe(custom404, overTLS: false, csp: true, "custom 404")
        let custom405 = try await Self.respond(to: Self.get("/only", method: "DELETE"), handler: router.handler)
        Self.expectSafe(custom405, overTLS: false, csp: true, "custom 405")
    }

    @Test("A 401 and a 429 that a middleware makes, and a 421 from allowedHosts, carry the headers")
    func middlewareResponses() async throws {
        let router = try Self.router { try $0.get("/x") { _ in try Response.json(["a": 1]) } }
        let unauthorized: Middleware = { _, _ in Response(status: .unauthorized) }
        let limited: Middleware = { _, _ in Response(status: .tooManyRequests).retrying(after: 3) }
        let hosts = try allowedHosts(["example.test"])

        let a = try await Self.respond(to: Self.get("/x"), handler: wrap(router.handler, with: [unauthorized]))
        #expect(a.status == 401)
        Self.expectSafe(a, overTLS: false, csp: true, "middleware 401")

        let b = try await Self.respond(to: Self.get("/x"), handler: wrap(router.handler, with: [limited]))
        #expect(b.status == 429)
        #expect(b.header("Retry-After") == "3")
        Self.expectSafe(b, overTLS: false, csp: true, "middleware 429")

        let c = try await Self.respond(to: Self.get("/x"), handler: wrap(router.handler, with: [hosts]))
        #expect(c.status == 421)
        Self.expectSafe(c, overTLS: false, csp: true, "allowedHosts 421")
    }

    @Test("The health route carries the headers")
    func health() async throws {
        let router = try Self.router { try $0.addHealth() }
        let response = try await Self.respond(to: Self.get("/health"), handler: router.handler)
        #expect(response.status == 200)
        Self.expectSafe(response, overTLS: false, csp: true, "health")
    }

    @Test("A handler that throws gets the transport's 500, and that carries the headers too")
    func thrownError() async throws {
        struct Boom: Error {}
        let response = try await Self.respond(to: Self.get("/x")) { _ in throw Boom() }
        #expect(response.status == 500)
        Self.expectSafe(response, overTLS: false, csp: true, "thrown 500")
    }

    // MARK: The transport's own refusals

    @Test("A request the transport refuses before any handler runs carries the headers: 400 for a malformed request line")
    func refusedOnTheWire() async throws {
        let harness = try await PipelineHarness(configuration: try Self.configuration(overTLS: false)) { _ in
            Response(status: .ok)
        }
        try await harness.send("NOT A REQUEST\r\n\r\n")
        let response = try #require(try await harness.readResponse())
        #expect(response.status == 400)
        Self.expectSafe(response, overTLS: false, csp: true, "wire 400")
        await harness.finish()
    }

    @Test("Every refusal the transport can make, as the server builds it and prepares it, carries the headers; a new case is covered by CaseIterable")
    func everyRefusal() throws {
        for overTLS in [false, true] {
            let context = ServerContext(configuration: try Self.configuration(overTLS: overTLS), handler: { _ in Response(status: .ok) })
            for refusal in Refusal.allCases {
                let prepared = ResponseRules.prepare(
                    context.response(for: refusal), policy: context.configuration.responseHeaders, overTLS: context.configuration.tls != nil)
                let fields = Dictionary(grouping: prepared.fields, by: { $0.name.rawName.lowercased() }).mapValues { $0.map(\.value) }
                let label = "\(refusal) overTLS=\(overTLS)"
                #expect(fields["x-content-type-options"] == ["nosniff"], "\(label): nosniff")
                #expect(fields["cache-control"]?.count == 1, "\(label): Cache-Control")
                #expect(fields["referrer-policy"] == ["no-referrer"], "\(label): Referrer-Policy")
                #expect(fields["x-frame-options"] == ["DENY"], "\(label): X-Frame-Options")
                #expect(fields["content-security-policy"] == [Self.jsonCSP], "\(label): CSP")
                #expect(fields["strict-transport-security"] == (overTLS ? ["max-age=604800"] : nil), "\(label): HSTS")
                #expect(fields["server"] == nil && fields["x-powered-by"] == nil, "\(label): names the software")
            }
        }
    }

    // MARK: Streams

    @Test("A streaming response's head carries the headers, before the first body byte")
    func streamingHead() async throws {
        let response = try await Self.respond(to: Self.get("/s")) { _ in
            .streaming(status: .ok) { writer in try await writer.write(Data("chunk".utf8)) }
        }
        #expect(response.status == 200)
        Self.expectSafe(response, overTLS: false, csp: false, "stream head")
    }

    @Test("An event stream keeps its own no-store, once, and gains the rest")
    func eventStreamHead() async throws {
        let response = try await Self.respond(to: Self.get("/events")) { _ in
            Response.eventStream { writer in try await writer.send(data: "hello") }
        }
        #expect(response.status == 200)
        Self.expectSafe(response, overTLS: false, csp: false, exactCacheControl: "no-store", "event stream head")
        #expect(response.header("Content-Type") == "text/event-stream")
    }

    @Test("Over TLS an event stream's head carries HSTS as well")
    func eventStreamHeadOverTLS() async throws {
        let response = try await Self.respond(to: Self.get("/events"), overTLS: true) { _ in
            Response.eventStream { writer in try await writer.send(data: "hello") }
        }
        #expect(response.status == 200)
        #expect(response.header("Content-Type") == "text/event-stream")
        Self.expectSafe(response, overTLS: true, csp: false, exactCacheControl: "no-store", "event stream head over TLS")
    }

    // MARK: The server says which policy it runs

    @Test("A server exposes its policy, so its owner can print an opt-out's reason at start; both initialisers do")
    func serverExposesPolicy() throws {
        let off = try ResponseHeaderPolicy.disabled(because: "a gateway in front sets these")
        let configuration = try ServiceConfiguration(port: 0, responseHeaders: off)
        let byHandler = HTTPServer(configuration: configuration, handler: { _ in Response(status: .ok) })
        #expect(byHandler.responseHeaderPolicy == off)
        #expect(byHandler.responseHeaderPolicy.optOutReason == "a gateway in front sets these")
        let byRouter = HTTPServer(configuration: configuration, router: Router())
        #expect(byRouter.responseHeaderPolicy.optOutReason == "a gateway in front sets these")
        let defaulted = HTTPServer(configuration: try ServiceConfiguration(port: 0), handler: { _ in Response(status: .ok) })
        #expect(defaulted.responseHeaderPolicy == .secure)
        #expect(defaulted.responseHeaderPolicy.optOutReason == nil)
    }
}
