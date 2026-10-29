import Foundation
import HTTPTypes
import Testing
@testable import SwiftHTTPService

/// Per-route body bounds and middleware, on the router.
@Suite("Route limits")
struct RouteLimitTests {

    private static let ok: Handler = { _ in Response(status: .ok) }

    private static func router() throws -> Router {
        var router = Router()
        try router.post("/small", maximumBodyBytes: 10, ok)
        try router.post("/big", maximumBodyBytes: 5_000_000, ok)
        try router.post("/unlimited", ok)                                    // no override: the global bound applies
        try router.get("/users/{id}", maximumBodyBytes: 7, ok)
        try router.get("/users/me", maximumBodyBytes: 3, ok)                 // a literal beats the parameter
        try router.put("/zero", maximumBodyBytes: 0, ok)
        return router
    }

    @Test("A route's bound is found from the method and target alone, before any body is read")
    func lookup() throws {
        let router = try Self.router()
        #expect(router.maximumBodyBytes(for: .post, target: "/small") == 10)
        #expect(router.maximumBodyBytes(for: .post, target: "/big") == 5_000_000)
        #expect(router.maximumBodyBytes(for: .post, target: "/small?x=1") == 10)       // the query is not part of the route
        #expect(router.maximumBodyBytes(for: .put, target: "/zero") == 0)               // zero is a bound, not "none"
    }

    @Test("A route with no bound, an unknown path, a method the path lacks, and a bad target all have none, so the global bound applies")
    func noBound() throws {
        let router = try Self.router()
        #expect(router.maximumBodyBytes(for: .post, target: "/unlimited") == nil)
        #expect(router.maximumBodyBytes(for: .post, target: "/nowhere") == nil)
        #expect(router.maximumBodyBytes(for: .delete, target: "/small") == nil)
        #expect(router.maximumBodyBytes(for: .post, target: "//a") == nil)
        #expect(router.maximumBodyBytes(for: .post, target: "small") == nil)
    }

    @Test("The same rule as routing decides which route: a literal beats a parameter, and HEAD is served by GET")
    func sameRuleAsRouting() throws {
        let router = try Self.router()
        #expect(router.maximumBodyBytes(for: .get, target: "/users/me") == 3)
        #expect(router.maximumBodyBytes(for: .get, target: "/users/42") == 7)
        #expect(router.maximumBodyBytes(for: .head, target: "/users/42") == 7)
        #expect(router.maximumBodyBytes(for: .head, target: "/users/me") == 3)
    }

    @Test("A bound outside 0 to 64 MiB is a registration error, naming the pattern and not the number; the edges are accepted", arguments: [
        (-1, false), (0, true), (67_108_864, true), (67_108_865, false),
    ])
    func validation(_ pair: (Int, Bool)) {
        var router = Router()
        if pair.1 {
            #expect(throws: Never.self) { try router.post("/x", maximumBodyBytes: pair.0, Self.ok) }
        } else {
            #expect(throws: RouterError.invalidBodyLimit("/x")) { try router.post("/x", maximumBodyBytes: pair.0, Self.ok) }
        }
    }

    @Test("A refused registration leaves the router as it was")
    func refusedRegistrationRegistersNothing() async throws {
        var router = Router()
        _ = try? router.post("/x", maximumBodyBytes: -1, Self.ok)
        #expect(router.maximumBodyBytes(for: .post, target: "/x") == nil)
        let response = try await router.route(try Request(method: .post, target: "/x", headers: HTTPFields(), body: Data()))
        #expect(response.status == .notFound)
    }

    // MARK: Per-route middleware

    private actor Trace {
        var events: [String] = []
        func add(_ event: String) { events.append(event) }
    }

    private static func layer(_ name: String, _ trace: Trace) -> Middleware {
        { request, next in
            await trace.add("\(name) in")
            let response = try await next(request)
            await trace.add("\(name) out")
            return response
        }
    }

    @Test("Route middleware runs inside the global middleware, first listed outermost, and only for its own route")
    func routeMiddleware() async throws {
        let trace = Trace()
        var router = Router()
        try router.get("/guarded", middleware: [Self.layer("a", trace), Self.layer("b", trace)]) { _ in
            await trace.add("handler")
            return Response(status: .ok)
        }
        try router.get("/open") { _ in
            await trace.add("open handler")
            return Response(status: .ok)
        }
        let handler = wrap(router.handler, with: [Self.layer("global", trace)])
        _ = try await handler(try Request(method: .get, target: "/guarded", headers: HTTPFields(), body: Data()))
        #expect(await trace.events == ["global in", "a in", "b in", "handler", "b out", "a out", "global out"])
        await trace.add("--")
        _ = try await handler(try Request(method: .get, target: "/open", headers: HTTPFields(), body: Data()))
        #expect(await trace.events.suffix(4) == ["--", "global in", "open handler", "global out"])
    }

    @Test("A route's middleware can refuse before the handler runs, and a different route's limiter is its own")
    func routeRateLimit() async throws {
        let limiter = try RateLimiter(try RateLimit(requests: 1, per: .seconds(60), burst: 1))
        var router = Router()
        try router.post("/login", middleware: [rateLimit(limiter)]) { _ in Response(status: .ok) }
        try router.post("/other") { _ in Response(status: .ok) }
        let handler = router.handler
        func post(_ path: String) async throws -> HTTPResponse.Status {
            try await handler(try Request(method: .post, target: path, headers: HTTPFields(), body: Data(), remoteAddress: "198.51.100.1")).status
        }
        #expect(try await post("/login") == .ok)
        #expect(try await post("/login") == .tooManyRequests)
        #expect(try await post("/other") == .ok)
        #expect(try await post("/other") == .ok)
    }
}
