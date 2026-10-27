import Foundation
import HTTPTypes
import Testing
@testable import SwiftHTTPService

/// Conditional requests, as RFC 9110 section 13.1.2 defines `If-None-Match`: weak comparison, `*`, a list,
/// and a header that does not parse is ignored (so the full response is sent, never a wrong `304`).
@Suite("Entity tags and If-None-Match")
struct ConditionalTests {

    private func tag(_ opaque: String, weak: Bool = false) throws -> EntityTag {
        try #require(EntityTag(opaque: opaque, isWeak: weak))
    }

    // MARK: Entity tags

    @Test("A strong tag is written quoted, and a weak one with W/")
    func headerValue() throws {
        #expect(try tag("abc").headerValue == "\"abc\"")
        #expect(try tag("abc", weak: true).headerValue == "W/\"abc\"")
    }

    static let badOpaque = ["a\"b", "a b", "a\tb", "a\nb", "é", "a\u{7f}b"]

    @Test("An opaque value with a quote, a space, a control or a non-ASCII character is refused", arguments: badOpaque)
    func invalidOpaque(_ opaque: String) {
        #expect(EntityTag(opaque: opaque, isWeak: false) == nil)
    }

    @Test("Printable ASCII without a quote or a space is accepted, including punctuation")
    func validOpaque() {
        let punctuation = "c_7f3a-1.0-3f9c!#$%&'()*+,/:;<=>?@[]^_`{|}~"
        #expect(EntityTag(opaque: punctuation, isWeak: false)?.opaque == punctuation)
        #expect(EntityTag(opaque: "", isWeak: false)?.headerValue == "\"\"")   // "" is a legal tag
    }

    // MARK: If-None-Match

    struct Case: Sendable, CustomTestStringConvertible {
        let header: String
        let current: String
        let matches: Bool
        var testDescription: String { "\(header) vs \(current)" }
    }

    static let cases = [
        Case(header: "\"abc\"", current: "abc", matches: true),
        Case(header: "\"abd\"", current: "abc", matches: false),
        // Weak comparison: the W/ prefix is ignored.
        Case(header: "W/\"abc\"", current: "abc", matches: true),
        // A list: any member.
        Case(header: "\"x\", \"abc\"", current: "abc", matches: true),
        Case(header: "\"abc\",\"x\"", current: "abc", matches: true),
        Case(header: "\"x\" ,  \"y\"", current: "abc", matches: false),
        Case(header: "  \"abc\"  ", current: "abc", matches: true),
        // Empty list elements are allowed by RFC 9110 section 5.6.1 and ignored.
        Case(header: ", \"abc\"", current: "abc", matches: true),
        Case(header: "\"abc\",", current: "abc", matches: true),
        // A comma inside the quotes is part of the tag, not a separator.
        Case(header: "\"a,b\"", current: "a,b", matches: true),
        Case(header: "\"a\", \"b\"", current: "a,b", matches: false),
        // The wildcard matches any current representation.
        Case(header: "*", current: "abc", matches: true),
        Case(header: " * ", current: "abc", matches: true),
        // Anything that does not parse is ignored as a whole: the full response is sent.
        Case(header: "", current: "abc", matches: false),
        Case(header: "abc", current: "abc", matches: false),          // unquoted
        Case(header: "\"abc", current: "abc", matches: false),        // unterminated
        Case(header: "abc\"", current: "abc", matches: false),
        Case(header: "w/\"abc\"", current: "abc", matches: false),    // the prefix is case sensitive
        Case(header: "W/ \"abc\"", current: "abc", matches: false),
        Case(header: "W/abc", current: "abc", matches: false),
        Case(header: "Wx\"abc\"", current: "abc", matches: false),       // W must be followed by a slash
        Case(header: "W\"abc\"", current: "abc", matches: false),
        // A tag with a non-ASCII byte is valid syntax (obs-text) and simply does not match ours.
        Case(header: "\"é\", \"abc\"", current: "abc", matches: true),
        Case(header: "*, \"abc\"", current: "abc", matches: false),   // * cannot join a list
        Case(header: "\"abc\", *", current: "abc", matches: false),
        Case(header: "\"abc\" \"def\"", current: "abc", matches: false), // no separator
        Case(header: "\"a\"b\"", current: "a", matches: false),
        // Case matters inside a tag.
        Case(header: "\"ABC\"", current: "abc", matches: false),
    ]

    @Test("If-None-Match matches as RFC 9110 says", arguments: cases)
    func matching(_ testCase: Case) throws {
        let current = try tag(testCase.current)
        #expect(Conditional.ifNoneMatch(testCase.header, matches: current) == testCase.matches)
    }

    @Test("A weak current tag matches a strong one with the same value, under weak comparison")
    func weakCurrent() throws {
        #expect(Conditional.ifNoneMatch("\"abc\"", matches: try tag("abc", weak: true)))
    }

    // MARK: Responding

    private actor Counter {
        private(set) var calls = 0
        func hit() { calls += 1 }
    }

    private func request(_ method: HTTPRequest.Method = .get, ifNoneMatch values: [String] = []) throws -> Request {
        var fields = HTTPFields()
        for value in values { fields.append(HTTPField(name: .ifNoneMatch, value: value)) }
        return try Request(method: method, target: "/v1/x", headers: fields, body: Data())
    }

    @Test("A matching GET is a 304 with the tag, and the response is never produced")
    func notModified() async throws {
        let counter = Counter()
        let response = try await Conditional.respond(to: try request(ifNoneMatch: ["\"abc\""]), etag: try tag("abc")) {
            await counter.hit()
            return .empty(.ok)
        }
        #expect(response.status == .notModified)
        #expect(response.headers[.eTag] == "\"abc\"")
        #expect(response.body.isEmpty)
        #expect(await counter.calls == 0)
    }

    @Test("A GET that does not match is produced, and carries the tag")
    func modified() async throws {
        let counter = Counter()
        let response = try await Conditional.respond(to: try request(ifNoneMatch: ["\"old\""]), etag: try tag("new")) {
            await counter.hit()
            return try .json(["a": 1])
        }
        #expect(response.status == .ok)
        #expect(response.headers[.eTag] == "\"new\"")
        #expect(await counter.calls == 1)
    }

    @Test("A request with no If-None-Match is produced and carries the tag")
    func noHeader() async throws {
        let response = try await Conditional.respond(to: try request(), etag: try tag("abc")) { .empty(.ok) }
        #expect(response.status == .ok)
        #expect(response.headers[.eTag] == "\"abc\"")
    }

    @Test("HEAD is conditional too")
    func head() async throws {
        let response = try await Conditional.respond(to: try request(.head, ifNoneMatch: ["\"abc\""]), etag: try tag("abc")) { .empty(.ok) }
        #expect(response.status == .notModified)
    }

    @Test("Other methods are not made conditional by If-None-Match")
    func otherMethods() async throws {
        for method in [HTTPRequest.Method.post, .put, .delete, .patch] {
            let response = try await Conditional.respond(to: try request(method, ifNoneMatch: ["*"]), etag: try tag("abc")) { .empty(.ok) }
            #expect(response.status == .ok)
        }
    }

    @Test("Several If-None-Match fields are read as one list")
    func multipleFields() async throws {
        let response = try await Conditional.respond(to: try request(ifNoneMatch: ["\"x\"", "\"abc\""]), etag: try tag("abc")) { .empty(.ok) }
        #expect(response.status == .notModified)
    }

    @Test("A tag the handler already set is kept")
    func existingTag() async throws {
        let response = try await Conditional.respond(to: try request(), etag: try tag("abc")) {
            Response.empty(.ok).setting(.eTag, to: "\"theirs\"")
        }
        #expect(response.headers[.eTag] == "\"theirs\"")
    }

    @Test("An error from the producer is not hidden")
    func errorsPropagate() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            _ = try await Conditional.respond(to: try self.request(), etag: try self.tag("abc")) { throw Boom() }
        }
    }
}

@Suite("Health route")
struct HealthTests {

    @Test("The health route answers 200 with a constant body")
    func health() async throws {
        var router = Router()
        try router.addHealth()
        let request = try Request(method: .get, target: "/health", headers: HTTPFields(), body: Data())
        let response = try await router.handler(request)
        #expect(response.status == .ok)
        #expect(response.headers[.contentType] == "application/json")
        #expect(String(decoding: response.body, as: UTF8.self) == #"{"status":"ok"}"#)
    }

    @Test("The path can be chosen, and HEAD works")
    func customPath() async throws {
        var router = Router()
        try router.addHealth(at: "/internal/live")
        let request = try Request(method: .head, target: "/internal/live", headers: HTTPFields(), body: Data())
        #expect(try await router.handler(request).status == .ok)
        let other = try Request(method: .get, target: "/health", headers: HTTPFields(), body: Data())
        #expect(try await router.handler(other).status == .notFound)
    }

    @Test("Registering health twice at the same path is refused like any duplicate")
    func twice() throws {
        var router = Router()
        try router.addHealth()
        #expect(throws: RouterError.self) { try router.addHealth() }
    }
}
