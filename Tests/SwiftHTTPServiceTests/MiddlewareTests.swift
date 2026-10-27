import Foundation
import HTTPTypes
import Testing
@testable import SwiftHTTPService

/// A recording of what ran, in order. An actor, because handlers are `@Sendable` and may run anywhere.
private actor Journal {
    private(set) var entries: [String] = []
    func add(_ entry: String) { entries.append(entry) }
}

@Suite("Middleware")
struct MiddlewareTests {

    private func request(_ target: String = "/") throws -> Request {
        try Request(method: .get, target: target, headers: HTTPFields(), body: Data())
    }

    @Test("Middleware run outermost first on the way in and last on the way out")
    func order() async throws {
        let journal = Journal()
        func tag(_ name: String) -> Middleware {
            { request, next in
                await journal.add("\(name) in")
                let response = try await next(request)
                await journal.add("\(name) out")
                return response
            }
        }
        let handler: Handler = { _ in await journal.add("handler"); return .empty(.ok) }
        let wrapped = wrap(handler, with: [tag("a"), tag("b"), tag("c")])
        _ = try await wrapped(try request())
        #expect(await journal.entries == ["a in", "b in", "c in", "handler", "c out", "b out", "a out"])
    }

    @Test("Middleware can stop a request: the handler is never reached")
    func shortCircuit() async throws {
        let journal = Journal()
        let gate: Middleware = { _, _ in try .problem(Problem(status: .unauthorized, code: "unauthorized")) }
        let handler: Handler = { _ in await journal.add("handler"); return .empty(.ok) }
        let response = try await wrap(handler, with: [gate])(try request())
        #expect(response.status == .unauthorized)
        #expect(await journal.entries.isEmpty)
    }

    @Test("Middleware can change the request for what follows, through the context")
    func contextFlowsInward() async throws {
        enum Who: ContextKey { typealias Value = String }
        let identify: Middleware = { request, next in
            var request = request
            request.context[Who.self] = "alice"
            return try await next(request)
        }
        let handler: Handler = { request in .empty(request.context[Who.self] == "alice" ? .ok : .forbidden) }
        #expect(try await wrap(handler, with: [identify])(try request()).status == .ok)
    }

    @Test("Middleware can change the response on the way out")
    func responseFlowsOutward() async throws {
        let stamp: Middleware = { request, next in try await next(request).setting(.server, to: "kit") }
        let handler: Handler = { _ in .empty(.ok) }
        let response = try await wrap(handler, with: [stamp])(try request())
        #expect(response.headers[.server] == "kit")
    }

    @Test("No middleware leaves the handler as it was")
    func none() async throws {
        let handler: Handler = { _ in .empty(.accepted) }
        let response = try await wrap(handler, with: [])(try request())
        #expect(response.status == .accepted)
    }

    @Test("An error from a handler passes outward through the middleware that wrapped it")
    func errorsPropagate() async {
        struct Boom: Error {}
        let journal = Journal()
        let observe: Middleware = { request, next in
            do { return try await next(request) } catch { await journal.add("saw error"); throw error }
        }
        let handler: Handler = { _ in throw Boom() }
        await #expect(throws: Boom.self) { try await wrap(handler, with: [observe])(try self.request()) }
        #expect(await journal.entries == ["saw error"])
    }
}
