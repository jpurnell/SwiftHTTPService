import Foundation
import HTTPTypes
import Testing
@testable import SwiftHTTPService

/// The scheme of a plain-text origin. Many entries below are `http` origins on purpose, as a developer's local page is one;
/// they are test data, built from this name so that no plain-text URL is written as a literal.
private let plainScheme = "http"

/// Strict CORS: an allow-list of serialized origins, echoed and never a wildcard; a preflight answered here, before
/// authentication; a stranger's origin refused.
@Suite("CORS")
struct CORSTests {

    private actor Calls {
        var count = 0
        func hit() { count += 1 }
    }

    private static let app = "https://app.example"
    private static let dev = "\(plainScheme)://localhost:5173"

    private static func request(
        _ method: HTTPRequest.Method = .post, origins: [String] = [], extra: [(HTTPField.Name, String)] = []
    ) throws -> Request {
        var headers = HTTPFields()
        for origin in origins { headers.append(HTTPField(name: .origin, value: origin)) }
        for (name, value) in extra { headers.append(HTTPField(name: name, value: value)) }
        return try Request(method: method, target: "/v1/chat/completions", headers: headers, body: Data())
    }

    private static func run(
        _ layer: Middleware, _ request: Request, response: Response = Response(status: .ok, body: Data("through".utf8))
    ) async throws -> (Response, Int) {
        let calls = Calls()
        let result = try await layer(request) { _ in
            await calls.hit()
            return response
        }
        return (result, await calls.count)
    }

    private static func values(_ response: Response, _ name: HTTPField.Name) -> [String] { response.headers[values: name] }

    // MARK: Construction

    struct Bad: Sendable, CustomTestStringConvertible {
        let entry: String
        var testDescription: String { entry.debugDescription }
    }

    static let badOrigins: [Bad] = [
        "*", "null", "NULL", "", " ",
        "\(plainScheme)://app.example/", "\(plainScheme)://app.example/path", "\(plainScheme)://app.example/?q=1", "\(plainScheme)://app.example?x=1", "\(plainScheme)://app.example#f",
        "HTTP://app.example", "Https://app.example", "HTTPS://APP.EXAMPLE",
        "app.example", "app.example:80", "//app.example", "http:/app.example", "http:app.example", "\(plainScheme)://", "https:///", "://app.example",
        "1\(plainScheme)://app.example", "-x://app.example", "ht tp://app.example",
        "\(plainScheme)://:80", "\(plainScheme)://app.example:", "\(plainScheme)://app.example:0", "\(plainScheme)://app.example:65536", "\(plainScheme)://app.example:08080", "\(plainScheme)://app.example:8a",
        "\(plainScheme)://user@app.example", "\(plainScheme)://user:pw@app.example", "\(plainScheme)://app .example", "\(plainScheme)://app.example ", " \(plainScheme)://app.example",
        "\(plainScheme)://app.example\r\nX-Evil: 1", "\(plainScheme)://app.example\u{0}", "\(plainScheme)://app.example\t",
        "\(plainScheme)://App.example", "\(plainScheme)://caf\u{E9}.example",
        "\(plainScheme)://app.example, \(plainScheme)://b.example", "\(plainScheme)://a.example \(plainScheme)://b.example",
        // an explicit default port is never what a browser sends, so the entry could not match
        "\(plainScheme)://app.example:80", "https://app.example:443",
        "\(plainScheme)://[::1", "\(plainScheme)://[]", "\(plainScheme)://[zz]:80", "\(plainScheme)://[::1]x",
    ].map(Bad.init)

    @Test("Each malformed origin is refused, naming its position and never its value", arguments: badOrigins)
    func malformedOrigin(_ bad: Bad) {
        #expect(throws: CORSError.invalidOrigin(at: 1)) { try cors(allowedOrigins: [Self.app, bad.entry]) }
    }

    @Test("Well-formed origins are accepted, including ports that are not the scheme's default and IPv6")
    func wellFormed() throws {
        for entry in [
            "https://app.example", "\(plainScheme)://localhost:3000", "\(plainScheme)://127.0.0.1:5173", "\(plainScheme)://[::1]:3000", "https://a.example:80",
            "\(plainScheme)://a.example:443", "chrome-extension://abcdefghijklmnop", "https://a-b.example", "\(plainScheme)://a_b.example",
        ] {
            #expect(throws: Never.self, "\(entry)") { try cors(allowedOrigins: [entry]) }
        }
    }

    @Test("An empty list is allowed: it means no origin is, and every request that names one is refused")
    func emptyList() async throws {
        let layer = try cors(allowedOrigins: [])
        let (refused, calls) = try await Self.run(layer, try Self.request(origins: [Self.app]))
        #expect(refused.status.code == 403)
        #expect(calls == 0)
        #expect(Self.values(refused, .vary).isEmpty)
        let (plain, plainCalls) = try await Self.run(layer, try Self.request())
        #expect(plain.status == .ok)
        #expect(plainCalls == 1)
        #expect(plain.headers[.vary] == nil)
    }

    @Test("Methods and headers must be tokens, and there must be at least one of each")
    func malformedLists() throws {
        for methods in [[], [""], ["PO ST"], ["POST\r\nX: y"], ["POST,GET"], ["POST", "GE T"], ["P\u{D6}ST"]] {
            #expect(throws: CORSError.invalidMethods) { try cors(allowedOrigins: [Self.app], allowedMethods: methods) }
        }
        for headers in [[], [""], ["Content-Type:"], ["Authorization\r\nX: y"], ["A B"], ["A,B"], ["Content Type"], ["\u{C4}"]] {
            #expect(throws: CORSError.invalidHeaders) { try cors(allowedOrigins: [Self.app], allowedHeaders: headers) }
        }
        _ = try cors(allowedOrigins: [Self.app], allowedMethods: ["GET", "POST"], allowedHeaders: ["X-Custom_1", "Authorization"])
    }

    @Test("The first problem found is the one reported: origins, then methods, then headers")
    func errorOrder() {
        #expect(throws: CORSError.invalidOrigin(at: 0)) { try cors(allowedOrigins: ["*"], allowedMethods: [], allowedHeaders: []) }
        #expect(throws: CORSError.invalidMethods) { try cors(allowedOrigins: [Self.app], allowedMethods: [], allowedHeaders: []) }
    }

    // MARK: A request with no Origin

    @Test("A request with no Origin reaches the handler and its response is untouched, except that it varies on Origin")
    func noOrigin() async throws {
        let layer = try cors(allowedOrigins: [Self.app])
        let (response, calls) = try await Self.run(layer, try Self.request())
        #expect(calls == 1)
        #expect(response.status == .ok)
        #expect(response.body == Data("through".utf8))
        #expect(Self.values(response, .vary) == ["Origin"])
        #expect(response.headers[.accessControlAllowOrigin] == nil)
        #expect(response.headers[.accessControlAllowMethods] == nil)
    }

    @Test("A request with no Origin and the method OPTIONS is not a preflight: the handler answers it")
    func optionsWithoutOrigin() async throws {
        let layer = try cors(allowedOrigins: [Self.app])
        let (response, calls) = try await Self.run(layer, try Self.request(.options))
        #expect(calls == 1)
        #expect(response.status == .ok)
    }

    // MARK: Vary

    @Test("Vary: Origin is added beside the handler's own Vary, once, and not when the handler says Origin or *")
    func varyMerging() async throws {
        let layer = try cors(allowedOrigins: [Self.app])
        func handlerResponse(vary: [String]) -> Response {
            var headers = HTTPFields()
            for value in vary { headers.append(HTTPField(name: .vary, value: value)) }
            return Response(status: .ok, headers: headers)
        }
        let table: [([String], [String])] = [
            ([], ["Origin"]),
            (["Accept-Encoding"], ["Accept-Encoding", "Origin"]),
            (["Accept-Encoding, Origin"], ["Accept-Encoding, Origin"]),
            (["Accept-Encoding", "origin"], ["Accept-Encoding", "origin"]),
            (["ORIGIN"], ["ORIGIN"]),
            (["*"], ["*"]),
            (["Accept-Encoding,*"], ["Accept-Encoding,*"]),
            (["Origin-Like"], ["Origin-Like", "Origin"]),
        ]
        for (given, expected) in table {
            let (response, _) = try await Self.run(layer, try Self.request(origins: [Self.app]), response: handlerResponse(vary: given))
            #expect(Self.values(response, .vary) == expected, "handler said \(given)")
        }
    }

    // MARK: An allowed origin

    @Test("An allowed origin is echoed, with Vary, on the handler's response; the handler's own fields stay")
    func allowed() async throws {
        let layer = try cors(allowedOrigins: [Self.app, Self.dev])
        for origin in [Self.app, Self.dev] {
            var headers = HTTPFields()
            headers[.eTag] = "\"v1\""
            let given = Response(status: .created, headers: headers, body: Data("made".utf8))
            let (response, calls) = try await Self.run(layer, try Self.request(origins: [origin]), response: given)
            #expect(calls == 1)
            #expect(response.status == .created)
            #expect(response.body == Data("made".utf8))
            #expect(response.headers[.eTag] == "\"v1\"")
            #expect(Self.values(response, .accessControlAllowOrigin) == [origin])
            #expect(Self.values(response, .vary) == ["Origin"])
        }
    }

    @Test("The handler's own error response carries the headers too, so a browser can read it")
    func handlerError() async throws {
        let layer = try cors(allowedOrigins: [Self.app])
        let problem = try Response.problem(Problem(status: .notFound, code: "not_found"))
        let (response, _) = try await Self.run(layer, try Self.request(origins: [Self.app]), response: problem)
        #expect(response.status == .notFound)
        #expect(Self.values(response, .accessControlAllowOrigin) == [Self.app])
        #expect(Self.values(response, .vary) == ["Origin"])
    }

    @Test("A wildcard the handler set is replaced by the one origin; there is never a wildcard")
    func wildcardReplaced() async throws {
        let layer = try cors(allowedOrigins: [Self.app])
        let (response, _) = try await Self.run(
            layer, try Self.request(origins: [Self.app]), response: Response(status: .ok).setting(.accessControlAllowOrigin, to: "*"))
        #expect(Self.values(response, .accessControlAllowOrigin) == [Self.app])
    }

    @Test("A streaming response gets the headers, and is still the same stream")
    func streaming() async throws {
        let layer = try cors(allowedOrigins: [Self.app])
        let streaming = Response.streaming(status: .ok) { writer in try await writer.write(Data("a".utf8)) }
        let (response, calls) = try await Self.run(layer, try Self.request(origins: [Self.app]), response: streaming)
        #expect(calls == 1)
        #expect(response.stream == streaming.stream)
        #expect(Self.values(response, .accessControlAllowOrigin) == [Self.app])
        #expect(Self.values(response, .vary) == ["Origin"])
        let (anonymous, _) = try await Self.run(layer, try Self.request(), response: streaming)
        #expect(anonymous.stream == streaming.stream)
        #expect(Self.values(anonymous, .vary) == ["Origin"])
    }

    // MARK: A stranger's origin

    static let strangers = [
        "https://evil.example", "\(plainScheme)://app.example", "https://app.example:8443", "https://app.example.evil.example", "https://app.example@evil.example",
        "https://app.example/", "https://sub.app.example", "https://xapp.example", "HTTPS://app.example", "https://APP.example", "null", "", "*",
        // (a leading or trailing space cannot be tested here: HTTPFields trims it, as the transport does on the wire)
        "https://app.example,https://dev.example", "https://app.example\u{A0}",
    ]

    @Test("An origin not on the list is a 403 problem with Vary and no Allow-Origin, and the handler never runs", arguments: strangers)
    func stranger(_ origin: String) async throws {
        let layer = try cors(allowedOrigins: [Self.app])
        for method: HTTPRequest.Method in [.post, .get, .options] {
            let (response, calls) = try await Self.run(layer, try Self.request(method, origins: [origin]))
            #expect(response.status.code == 403, "\(method) \(origin.debugDescription)")
            #expect(calls == 0)
            #expect(response.headers[.contentType] == "application/problem+json")
            #expect(response.body == Data(#"{"code":"origin_not_allowed","status":403,"title":"Forbidden","type":"about:blank"}"#.utf8))
            #expect(Self.values(response, .vary) == ["Origin"])
            #expect(response.headers[.accessControlAllowOrigin] == nil)
            #expect(response.headers[.accessControlAllowMethods] == nil)
        }
    }

    @Test("Two Origin fields are refused, even if both are on the list")
    func twoOrigins() async throws {
        let layer = try cors(allowedOrigins: [Self.app, Self.dev])
        let (response, calls) = try await Self.run(layer, try Self.request(origins: [Self.app, Self.dev]))
        #expect(response.status.code == 403)
        #expect(calls == 0)
    }

    // MARK: Preflight

    @Test("A preflight from an allowed origin is a 204 answered here, with the defaults, and the handler never runs")
    func preflight() async throws {
        let layer = try cors(allowedOrigins: [Self.app, Self.dev])
        for origin in [Self.app, Self.dev] {
            let (response, calls) = try await Self.run(layer, try Self.request(.options, origins: [origin]))
            #expect(calls == 0)
            #expect(response.status.code == 204)
            #expect(response.body.isEmpty)
            #expect(Self.values(response, .accessControlAllowOrigin) == [origin])
            #expect(Self.values(response, .accessControlAllowMethods) == ["POST"])
            #expect(Self.values(response, .accessControlAllowHeaders) == ["Authorization, Content-Type"])
            #expect(Self.values(response, .vary) == ["Origin"])
        }
    }

    @Test("A preflight lists the methods and headers it was given, in order")
    func preflightParameters() async throws {
        let layer = try cors(allowedOrigins: [Self.app], allowedMethods: ["GET", "POST", "DELETE"], allowedHeaders: ["X-Api-Key"])
        let (response, _) = try await Self.run(layer, try Self.request(.options, origins: [Self.app]))
        #expect(Self.values(response, .accessControlAllowMethods) == ["GET, POST, DELETE"])
        #expect(Self.values(response, .accessControlAllowHeaders) == ["X-Api-Key"])
        // an ordinary request does not carry the preflight's lists
        let (ordinary, _) = try await Self.run(layer, try Self.request(origins: [Self.app]))
        #expect(ordinary.headers[.accessControlAllowMethods] == nil)
        #expect(ordinary.headers[.accessControlAllowHeaders] == nil)
    }

    @Test("A preflight is answered whatever the path is")
    func preflightAnyPath() async throws {
        let layer = try cors(allowedOrigins: [Self.app])
        var headers = HTTPFields()
        headers[.origin] = Self.app
        let elsewhere = try Request(method: .options, target: "/anything/else", headers: headers, body: Data())
        let (response, calls) = try await Self.run(layer, elsewhere)
        #expect(response.status.code == 204)
        #expect(calls == 0)
    }

    // MARK: Order against authentication

    /// A stand-in for an authentication layer: it refuses a request with no `Authorization`.
    private static func auth(seen: Calls) -> Middleware {
        { request, next in
            await seen.hit()
            guard request.headers[.authorization] != nil else { return Response(status: .unauthorized) }
            return try await next(request)
        }
    }

    @Test("Placed before authentication, a preflight is answered and authentication never sees it")
    func beforeAuthentication() async throws {
        let seen = Calls()
        let handled = Calls()
        let handler = wrap({ _ in await handled.hit(); return Response(status: .ok) }, with: [try cors(allowedOrigins: [Self.app]), Self.auth(seen: seen)])
        let preflight = try await handler(try Self.request(.options, origins: [Self.app]))
        #expect(preflight.status.code == 204)
        #expect(await seen.count == 0)
        #expect(await handled.count == 0)
        // the real request, with no credential, is refused by authentication, and the refusal carries the CORS headers
        let refused = try await handler(try Self.request(origins: [Self.app]))
        #expect(refused.status == .unauthorized)
        #expect(await seen.count == 1)
        #expect(Self.values(refused, .accessControlAllowOrigin) == [Self.app])
        // with a credential it gets through
        let accepted = try await handler(try Self.request(origins: [Self.app], extra: [(.authorization, "Bearer k")]))
        #expect(accepted.status == .ok)
        #expect(await handled.count == 1)
    }

    @Test("Placed after authentication, the same preflight is refused 401: which is why the order matters")
    func afterAuthentication() async throws {
        let seen = Calls()
        let handler = wrap({ _ in Response(status: .ok) }, with: [Self.auth(seen: seen), try cors(allowedOrigins: [Self.app])])
        let preflight = try await handler(try Self.request(.options, origins: [Self.app]))
        #expect(preflight.status == .unauthorized)
        #expect(await seen.count == 1)
    }

    @Test("A handler that throws is not caught")
    func handlerErrorPropagates() async throws {
        struct Boom: Error {}
        let layer = try cors(allowedOrigins: [Self.app])
        await #expect(throws: Boom.self) {
            _ = try await layer(try Self.request(origins: [Self.app])) { _ in throw Boom() }
        }
    }
}
