import Foundation
import HTTPTypes
import Testing
@testable import SwiftHTTPService

/// The request id: one on every response, taken from the caller only if it is safe to log.
@Suite("Request id")
struct RequestIDTests {

    private static func request(id: String? = nil) throws -> Request {
        var headers = HTTPFields()
        if let id, let name = HTTPField.Name("X-Request-ID") { headers[name] = id }
        return try Request(method: .get, target: "/x", headers: headers, body: Data())
    }

    /// A generator that counts, so the expected ids are known without reading them back from the code.
    // Justification: every read and write of the counter happens inside the lock.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var next = 0
        func make() -> String { lock.withLock { next += 1; return "gen-\(next)" } }
    }

    private static func run(_ request: Request, counter: Counter = Counter()) async throws -> (Response, String?) {
        let seen = Seen()
        let layer = requestID(generate: { counter.make() })
        let response = try await layer(request) { request in
            await seen.set(request.context[RequestID.self])
            return Response(status: .ok)
        }
        return (response, await seen.value)
    }

    private actor Seen {
        var value: String?
        func set(_ newValue: String?) { value = newValue }
    }

    @Test("With no id offered, one is generated, put in the context and on the response")
    func generated() async throws {
        let (response, seen) = try await Self.run(try Self.request())
        #expect(seen == "gen-1")
        #expect(response.headers[try #require(HTTPField.Name("X-Request-ID"))] == "gen-1")
    }

    struct Offered: Sendable, CustomTestStringConvertible {
        let id: String
        let accepted: Bool
        var testDescription: String { id.debugDescription }
    }

    // Worked out from the rule: 1 to 64 characters, each A-Z a-z 0-9 . _ -
    static let offers: [Offered] = [
        Offered(id: "abc-123_DEF.9", accepted: true),
        Offered(id: "a", accepted: true),
        Offered(id: String(repeating: "a", count: 64), accepted: true),
        Offered(id: String(repeating: "a", count: 65), accepted: false),
        Offered(id: "", accepted: false),
        Offered(id: "has space", accepted: false),
        Offered(id: "semi;colon", accepted: false),
        Offered(id: "quote\"", accepted: false),
        Offered(id: "slash/", accepted: false),
        Offered(id: "caf\u{E9}", accepted: false),
        Offered(id: "tab\tin", accepted: false),
        Offered(id: "%0d%0a", accepted: false),
    ]

    @Test("An offered id is used only if it is safe to put in a log; otherwise a fresh one replaces it, whole", arguments: offers)
    func offeredIDs(_ offered: Offered) async throws {
        let (response, seen) = try await Self.run(try Self.request(id: offered.id))
        let expected = offered.accepted ? offered.id : "gen-1"
        #expect(seen == expected)
        #expect(response.headers[try #require(HTTPField.Name("X-Request-ID"))] == expected)
    }

    @Test("A handler's own X-Request-ID is replaced by the request's id")
    func handlerCannotOverride() async throws {
        let layer = requestID(generate: { "mine" })
        let response = try await layer(try Self.request()) { _ in
            Response(status: .ok).setting(try #require(HTTPField.Name("X-Request-ID")), to: "theirs")
        }
        #expect(response.headers[try #require(HTTPField.Name("X-Request-ID"))] == "mine")
    }

    @Test("An error from the handler passes outward unchanged")
    func errorsPass() async throws {
        struct Boom: Error, Equatable {}
        let layer = requestID(generate: { "x" })
        await #expect(throws: Boom.self) {
            _ = try await layer(try Self.request()) { _ in throw Boom() }
        }
    }

    @Test("A different header name can be configured")
    func customHeader() async throws {
        let name = try #require(HTTPField.Name("X-Correlation-ID"))
        let layer = requestID(header: name, generate: { "c-1" })
        let response = try await layer(try Self.request()) { _ in Response(status: .ok) }
        #expect(response.headers[name] == "c-1")
    }
}
