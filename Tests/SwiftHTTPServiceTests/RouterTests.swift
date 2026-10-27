import Foundation
import HTTPTypes
import Testing
@testable import SwiftHTTPService

/// Routing, with every expectation worked out by hand: which handler a request reaches, what it captures,
/// and what is refused at registration rather than at request time.
@Suite("Router")
struct RouterTests {

    /// A handler that answers with its own name, so a test can see which one ran.
    private func named(_ name: String) -> Handler {
        { request in
            var parameters = request.pathParameters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            if parameters.isEmpty { parameters = "-" }
            return try .json(["handler": name, "parameters": parameters])
        }
    }

    private func request(_ method: HTTPRequest.Method = .get, _ target: String) throws -> Request {
        try Request(method: method, target: target, headers: HTTPFields(), body: Data())
    }

    private func answer(_ router: Router, _ method: HTTPRequest.Method = .get, _ target: String) async throws -> (status: Int, handler: String?, parameters: String?, response: Response) {
        let response = try await router.handler(try request(method, target))
        let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: String]
        return (response.status.code, object?["handler"], object?["parameters"], response)
    }

    private func sample() throws -> Router {
        var router = Router()
        try router.add(.get, "/", named("root"))
        try router.add(.get, "/v1", named("v1"))
        try router.add(.get, "/v1/corpora", named("corpora"))
        try router.add(.get, "/v1/corpora/{corpus}/status", named("status"))
        try router.add(.get, "/v1/corpora/{corpus}/projects/{project}", named("project"))
        try router.add(.get, "/v1/corpora/{corpus}/projects/{project}/trend", named("trend"))
        try router.add(.post, "/v1/auth/passkey/challenge", named("challenge"))
        return router
    }

    // MARK: Dispatch

    struct Case: Sendable, CustomTestStringConvertible {
        let method: HTTPRequest.Method
        let target: String
        let handler: String
        let parameters: String
        var testDescription: String { "\(method) \(target)" }
    }

    static let dispatch = [
        Case(method: .get, target: "/", handler: "root", parameters: "-"),
        Case(method: .get, target: "/v1", handler: "v1", parameters: "-"),
        Case(method: .get, target: "/v1/corpora", handler: "corpora", parameters: "-"),
        Case(method: .get, target: "/v1/corpora/c_1/status", handler: "status", parameters: "corpus=c_1"),
        Case(method: .get, target: "/v1/corpora/c_1/projects/alpha", handler: "project", parameters: "corpus=c_1,project=alpha"),
        Case(method: .get, target: "/v1/corpora/c_1/projects/alpha/trend", handler: "trend", parameters: "corpus=c_1,project=alpha"),
        Case(method: .post, target: "/v1/auth/passkey/challenge", handler: "challenge", parameters: "-"),
        // A query does not change the route.
        Case(method: .get, target: "/v1/corpora?x=1", handler: "corpora", parameters: "-"),
        // A parameter is the decoded segment, so an encoded slash is part of the value, not a separator.
        Case(method: .get, target: "/v1/corpora/a%2Fb/status", handler: "status", parameters: "corpus=a/b"),
        Case(method: .get, target: "/v1/corpora/caf%C3%A9/status", handler: "status", parameters: "corpus=café"),
    ]

    @Test("A request reaches the handler its path names, with its parameters", arguments: dispatch)
    func dispatches(_ testCase: Case) async throws {
        let result = try await answer(try sample(), testCase.method, testCase.target)
        #expect(result.status == 200)
        #expect(result.handler == testCase.handler)
        #expect(result.parameters == testCase.parameters)
    }

    // MARK: 404

    static let unknown = [
        "/nope", "/v1/", "/v1/corpora/", "/v1/corpora/c_1", "/v1/corpora/c_1/status/extra",
        "/V1", "/v1/corpora/c_1/Status", "/v1/corpora/c_1/projects",
    ]

    @Test("A path nothing matches is a 404 problem", arguments: unknown)
    func notFound(_ target: String) async throws {
        let result = try await answer(try sample(), .get, target)
        #expect(result.status == 404)
        #expect(result.response.headers[.contentType] == "application/problem+json")
        #expect(String(decoding: result.response.body, as: UTF8.self) == #"{"code":"not_found","status":404,"title":"Not Found","type":"about:blank"}"#)
    }

    @Test("An empty segment never matches a parameter")
    func emptyParameter() async throws {
        // A trailing slash after a parameter's position gives an empty last segment.
        #expect(try await answer(try sample(), .get, "/v1/corpora/c_1/projects/").status == 404)
    }

    @Test("Matching is case sensitive")
    func caseSensitive() async throws {
        #expect(try await answer(try sample(), .get, "/v1/CORPORA").status == 404)
    }

    // MARK: 405

    @Test("A known path with another method is a 405 that lists what is allowed")
    func methodNotAllowed() async throws {
        let result = try await answer(try sample(), .post, "/v1/corpora")
        #expect(result.status == 405)
        #expect(result.response.headers[.allow] == "GET, HEAD")
        #expect(String(decoding: result.response.body, as: UTF8.self) == #"{"code":"method_not_allowed","status":405,"title":"Method Not Allowed","type":"about:blank"}"#)
    }

    @Test("Allow lists every method registered on the path, sorted, with HEAD wherever GET is")
    func allowHeader() async throws {
        var router = Router()
        try router.add(.put, "/r", named("put"))
        try router.add(.get, "/r", named("get"))
        try router.add(.delete, "/r", named("delete"))
        let result = try await answer(router, .patch, "/r")
        #expect(result.status == 405)
        #expect(result.response.headers[.allow] == "DELETE, GET, HEAD, PUT")
    }

    // MARK: HEAD

    @Test("HEAD is answered by the GET handler, and the body is left for the transport to drop")
    func head() async throws {
        let result = try await answer(try sample(), .head, "/v1")
        #expect(result.status == 200)
        #expect(result.handler == "v1")
    }

    @Test("A HEAD handler of its own wins over the GET handler")
    func headOverride() async throws {
        var router = try sample()
        try router.add(.head, "/v1", named("v1-head"))
        #expect(try await answer(router, .head, "/v1").handler == "v1-head")
        #expect(try await answer(router, .get, "/v1").handler == "v1")
    }

    @Test("HEAD on a path with no GET is a 405")
    func headWithoutGet() async throws {
        #expect(try await answer(try sample(), .head, "/v1/auth/passkey/challenge").status == 405)
    }

    // MARK: Specificity

    @Test("A literal segment beats a parameter")
    func literalBeatsParameter() async throws {
        var router = Router()
        try router.add(.get, "/a/{x}", named("param"))
        try router.add(.get, "/a/special", named("literal"))
        #expect(try await answer(router, .get, "/a/special").handler == "literal")
        #expect(try await answer(router, .get, "/a/other").handler == "param")
        #expect(try await answer(router, .get, "/a/other").parameters == "x=other")
    }

    @Test("Registration order does not change which handler a request reaches")
    func orderIndependent() async throws {
        let routes: [(String, String)] = [
            ("/a/{x}/c", "xc"), ("/a/b/{y}", "by"), ("/a/{x}/{y}", "xy"), ("/a/b/c", "bc"), ("/{z}/b/c", "zbc"),
        ]
        let targets = ["/a/b/c", "/a/q/c", "/a/b/q", "/a/q/q", "/z/b/c", "/zz/b/c", "/a/b"]
        func table(_ order: [(String, String)]) async throws -> [String] {
            var router = Router()
            for (pattern, name) in order { try router.add(.get, pattern, named(name)) }
            var out: [String] = []
            for target in targets { out.append("\(target) -> \(try await answer(router, .get, target).handler ?? "none")") }
            return out
        }
        let reference = try await table(routes)
        var rotated = routes
        for _ in routes.indices {
            rotated.append(rotated.removeFirst())
            #expect(try await table(rotated) == reference)
        }
        #expect(try await table(routes.reversed()) == reference)
        // And the reference itself is the leftmost-literal rule, worked out by hand.
        #expect(reference == [
            "/a/b/c -> bc",     // all literals
            "/a/q/c -> xc",     // literal a, then x, then literal c beats y
            "/a/b/q -> by",     // literal a, literal b beats x
            "/a/q/q -> xy",
            "/z/b/c -> zbc",    // only the first segment can be a parameter
            "/zz/b/c -> zbc",
            "/a/b -> none",
        ])
    }

    @Test("A path that fits a parameter route only under another method is dispatched by method")
    func methodSelectsAmongMatches() async throws {
        var router = Router()
        try router.add(.get, "/a/special", named("get-literal"))
        try router.add(.post, "/a/{x}", named("post-param"))
        #expect(try await answer(router, .post, "/a/special").handler == "post-param")
        #expect(try await answer(router, .get, "/a/special").handler == "get-literal")
        // Allow is the union across everything that matches the path.
        let refused = try await answer(router, .delete, "/a/special")
        #expect(refused.status == 405)
        #expect(refused.response.headers[.allow] == "GET, HEAD, POST")
    }

    // MARK: Registration refusals

    static let badPatterns = [
        "", "v1", "/v1/", "/v1//x", "//", "/{}", "/{a b}", "/{1a}", "/{a", "/a}", "/{a}{b}", "/x{a}", "/{a}x",
        "/a/{id}/{id}", "/a%20b", "/a?b", "/a#b", "/a b", "/a\tb", "/{a-b}",
    ]

    @Test("A pattern that is not well formed is refused when it is registered", arguments: badPatterns)
    func invalidPattern(_ pattern: String) {
        var router = Router()
        #expect(throws: RouterError.self) { try router.add(.get, pattern, { _ in .empty(.ok) }) }
    }

    @Test("The same method and shape twice is refused, whatever the parameters are called")
    func duplicates() throws {
        var router = Router()
        try router.add(.get, "/a/{x}", { _ in .empty(.ok) })
        #expect(throws: RouterError.duplicate(method: "GET", pattern: "/a/{y}")) { try router.add(.get, "/a/{y}", { _ in .empty(.ok) }) }
        #expect(throws: RouterError.duplicate(method: "GET", pattern: "/a/{x}")) { try router.add(.get, "/a/{x}", { _ in .empty(.ok) }) }
        // Another method on the same shape is fine.
        try router.add(.put, "/a/{y}", { _ in .empty(.ok) })
    }

    @Test("A well-formed pattern with names, digits, dots and underscores is accepted and reachable")
    func validPatterns() async throws {
        let patterns: [(pattern: String, target: String)] = [
            ("/", "/"), ("/a", "/a"), ("/a-b/c_d", "/a-b/c_d"), ("/v1/{corpus_id}/x2", "/v1/q/x2"),
            ("/{a}/{b}/{c}", "/1/2/3"), ("/.well-known/thing", "/.well-known/thing"),
        ]
        for pair in patterns {
            var router = Router()
            try router.add(.get, pair.pattern, { _ in .empty(.ok) })
            #expect(try await answer(router, .get, pair.target).status == 200)
        }
    }

    // MARK: Replaceable refusals

    @Test("The 404 and 405 handlers can be replaced, so a server can make its refusals alike")
    func replaceable() async throws {
        let same: Handler = { _ in .empty(HTTPResponse.Status(code: 418)) }
        var router = Router(notFound: same, methodNotAllowed: { _, _ in .empty(HTTPResponse.Status(code: 418)) })
        try router.add(.get, "/a", named("a"))
        #expect(try await answer(router, .get, "/missing").status == 418)
        #expect(try await answer(router, .post, "/a").status == 418)
    }

    @Test("The handler given to a 405 is told which methods are allowed")
    func allowedPassed() async throws {
        var seen: [String] = []
        let box = Box()
        var router = Router(notFound: { _ in .empty(.notFound) }, methodNotAllowed: { _, allowed in
            await box.set(allowed.map(\.rawValue))
            return .empty(.methodNotAllowed)
        })
        try router.add(.get, "/a", named("a"))
        _ = try await answer(router, .delete, "/a")
        seen = await box.value
        #expect(seen == ["GET", "HEAD"])
    }

    private actor Box {
        private(set) var value: [String] = []
        func set(_ new: [String]) { value = new }
    }
}
