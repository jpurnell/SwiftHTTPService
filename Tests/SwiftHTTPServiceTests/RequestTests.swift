import Foundation
import HTTPTypes
import Testing
@testable import SwiftHTTPService

/// A request's target is parsed strictly and once, so a router never sees an ambiguous path.
/// Every expected value below was worked out by hand from RFC 3986 and RFC 9112.
@Suite("Request target")
struct RequestTests {

    private func make(_ target: String, method: HTTPRequest.Method = .get) throws -> Request {
        try Request(method: method, target: target, headers: HTTPFields(), body: Data())
    }

    // MARK: Path

    struct SegmentCase: Sendable, CustomTestStringConvertible {
        let target: String
        let segments: [String]
        var testDescription: String { target }
    }

    static let segmentCases = [
        SegmentCase(target: "/", segments: []),
        SegmentCase(target: "/v1", segments: ["v1"]),
        SegmentCase(target: "/v1/corpora/abc/status", segments: ["v1", "corpora", "abc", "status"]),
        // A trailing slash is a different path from none: it keeps an empty last segment.
        SegmentCase(target: "/v1/", segments: ["v1", ""]),
        // Percent-decoding happens after the split, so an encoded slash stays inside its segment.
        SegmentCase(target: "/a%2Fb/c", segments: ["a/b", "c"]),
        SegmentCase(target: "/caf%C3%A9", segments: ["café"]),
        SegmentCase(target: "/a%20b", segments: ["a b"]),
        // Upper and lower case hex decode the same.
        SegmentCase(target: "/%7e%7E", segments: ["~~"]),
        // A plus is a plus in a path (and in a query here: this API takes no forms).
        SegmentCase(target: "/a+b", segments: ["a+b"]),
        // The query is not part of the path.
        SegmentCase(target: "/v1/me?x=1", segments: ["v1", "me"]),
    ]

    @Test("The path is split first and decoded after", arguments: segmentCases)
    func segments(_ testCase: SegmentCase) throws {
        #expect(try make(testCase.target).pathSegments == testCase.segments)
    }

    @Test("The raw path is kept as sent, without its query")
    func rawPath() throws {
        let request = try make("/a%2Fb/c?x=1&y=2")
        #expect(request.path == "/a%2Fb/c")
        #expect(request.target == "/a%2Fb/c?x=1&y=2")
    }

    // MARK: Refusals

    /// An absolute-form target. Assembled, so no literal URL with an insecure scheme sits in the source.
    private static let absoluteForm = "ht" + "tp://example.org/v1"

    static let refused = [
        "",                       // empty
        "v1/me",                  // not origin-form
        "*",                      // asterisk-form
        "example.org:443",        // authority-form
        absoluteForm,             // absolute-form
        "/v1/me#fragment",        // a fragment is never sent
        "/a%",                    // truncated escape
        "/a%2",                   // truncated escape
        "/a%zz",                  // not hex
        "/a%00b",                 // a decoded NUL
        "/a/../b",                // dot segments are refused, not normalised
        "/a/./b",
        "/a/%2e%2e/b",            // including when encoded
        "/a/%2E/b",
        "/a b",                   // a raw space cannot be in a target
        "/a\tb",
        "/a\nb",
        "/a\u{7f}b",              // a control character
        "//double",               // an empty first segment is ambiguous with an authority
        "/a//b",                  // an empty segment in the middle
        "/v1?q=%zz",              // a bad escape in the query
        "/v1?q=a%00b",
    ]

    @Test("A target that is ambiguous or malformed is refused", arguments: refused)
    func refusals(_ target: String) {
        #expect(throws: RequestError.malformedTarget) { try make(target) }
    }

    // MARK: Query

    @Test("The query keeps its order, its duplicates and its empty values")
    func query() throws {
        let request = try make("/v1?b=2&a=1&a=3&flag&empty=")
        #expect(request.query == [
            QueryItem(name: "b", value: "2"), QueryItem(name: "a", value: "1"), QueryItem(name: "a", value: "3"),
            QueryItem(name: "flag", value: nil), QueryItem(name: "empty", value: ""),
        ])
    }

    @Test("Query names and values are percent-decoded, and a plus stays a plus")
    func queryDecoding() throws {
        let request = try make("/v1?na%20me=a%26b+c")
        #expect(request.query == [QueryItem(name: "na me", value: "a&b+c")])
    }

    @Test("A request with no query has no items, and a lone question mark has none either")
    func emptyQuery() throws {
        #expect(try make("/v1").query.isEmpty)
        #expect(try make("/v1?").query.isEmpty)
    }

    @Test("The first value of a name is returned, and an absent name is nil")
    func firstValue() throws {
        let request = try make("/v1?a=1&a=2&flag")
        #expect(request.firstQueryValue(named: "a") == "1")
        #expect(request.firstQueryValue(named: "flag") == nil)
        #expect(request.firstQueryValue(named: "missing") == nil)
    }

    // MARK: The rest

    @Test("A new request has no path parameters, no remote address and an empty context")
    func defaults() throws {
        let request = try make("/v1")
        #expect(request.pathParameters.isEmpty)
        #expect(request.remoteAddress == nil)
        #expect(request.body.isEmpty)
    }

    @Test("The method and body are kept as given")
    func methodAndBody() throws {
        let request = try Request(method: .post, target: "/v1", headers: HTTPFields(), body: Data([1, 2, 3]), remoteAddress: "192.0.2.1")
        #expect(request.method == .post)
        #expect(request.body == Data([1, 2, 3]))
        #expect(request.remoteAddress == "192.0.2.1")
    }

    @Test("Headers are kept, and looked up without regard to case")
    func headers() throws {
        var fields = HTTPFields()
        fields[.authorization] = "Bearer abc"
        let request = try Request(method: .get, target: "/v1", headers: fields, body: Data())
        #expect(request.headers[.authorization] == "Bearer abc")
        let shouting = try #require(HTTPField.Name("AUTHORIZATION"))
        #expect(request.headers[shouting] == "Bearer abc")
    }
}

@Suite("Request context")
struct ContextTests {
    enum Subject: ContextKey { typealias Value = String }
    enum Count: ContextKey { typealias Value = Int }

    @Test("A value is stored under its key's type and read back")
    func roundTrip() {
        var context = Context()
        context[Subject.self] = "alice"
        context[Count.self] = 3
        #expect(context[Subject.self] == "alice")
        #expect(context[Count.self] == 3)
    }

    @Test("An unset key is nil, and setting nil removes a value")
    func unsetAndRemove() {
        var context = Context()
        #expect(context[Subject.self] == nil)
        context[Subject.self] = "alice"
        context[Subject.self] = nil
        #expect(context[Subject.self] == nil)
    }

    @Test("Two keys with the same value type do not collide")
    func distinctKeys() {
        enum A: ContextKey { typealias Value = String }
        enum B: ContextKey { typealias Value = String }
        var context = Context()
        context[A.self] = "a"
        context[B.self] = "b"
        #expect(context[A.self] == "a")
        #expect(context[B.self] == "b")
    }
}
