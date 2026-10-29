import Foundation
import HTTPTypes
import Testing
@testable import SwiftHTTPService

/// Response helpers, redirects and cookies. Expected values come from the RFCs the rules cite (6265 for cookies,
/// 9110 for redirects and content types), not from the code.
@Suite("Response helpers")
struct ResponseHelperTests {

    private static let nosniff = HTTPField.Name("X-Content-Type-Options")

    // MARK: Typed bodies

    struct Typed: Sendable, CustomTestStringConvertible {
        let name: String
        let response: Response
        let contentType: String
        var testDescription: String { name }
    }

    static let typed: [Typed] = [
        Typed(name: "html", response: .html("<p>é</p>"), contentType: "text/html; charset=utf-8"),
        Typed(name: "text", response: .text("é"), contentType: "text/plain; charset=utf-8"),
        Typed(name: "javascript", response: .javascript("let a = 1"), contentType: "text/javascript; charset=utf-8"),
        Typed(name: "css", response: .css("a{}"), contentType: "text/css; charset=utf-8"),
        Typed(name: "png", response: .png(Data([0x89, 0x50, 0x4E, 0x47])), contentType: "image/png"),
    ]

    @Test("Each helper sets its content type (with a charset for text) and nosniff, so a browser cannot guess another type", arguments: typed)
    func contentTypes(_ c: Typed) throws {
        #expect(c.response.status == .ok)
        #expect(c.response.headers[.contentType] == c.contentType)
        #expect(c.response.headers[try #require(Self.nosniff)] == "nosniff")
    }

    @Test("Text is encoded as UTF-8: the bytes of é are 0xC3 0xA9")
    func utf8Body() {
        #expect(Response.html("é").body == Data([0xC3, 0xA9]))
    }

    @Test("A status and a Cache-Control can be given")
    func statusAndCache() {
        let response = Response.html("x", status: .notFound, cacheControl: "no-store")
        #expect(response.status == .notFound)
        #expect(response.headers[.cacheControl] == "no-store")
        #expect(Response.html("x").headers[.cacheControl] == nil)
    }

    // MARK: Redirects

    struct Redirect: Sendable, CustomTestStringConvertible {
        let location: String
        let allowing: [String]
        let ok: Bool
        var testDescription: String { "\(location.debugDescription) allowing \(allowing)" }
    }

    // A redirect built from input must not leave the site: only a path-absolute reference, or an absolute one on an
    // origin the caller named, and the origin is matched whole (a prefix of a longer host is a different host).
    static let redirects: [Redirect] = [
        Redirect(location: "/", allowing: [], ok: true),
        Redirect(location: "/a/b?c=d#e", allowing: [], ok: true),
        Redirect(location: "//evil.example", allowing: [], ok: false),         // protocol-relative
        Redirect(location: "/\\evil.example", allowing: [], ok: false),         // browsers read \ as /
        Redirect(location: "\\\\evil.example", allowing: [], ok: false),
        Redirect(location: "https://evil.example/", allowing: [], ok: false),
        Redirect(location: "javascript:alert(1)", allowing: [], ok: false),
        Redirect(location: "relative/path", allowing: [], ok: false),
        Redirect(location: "", allowing: [], ok: false),
        Redirect(location: "/a\r\nSet-Cookie: x=1", allowing: [], ok: false),  // response splitting
        Redirect(location: "/a\nb", allowing: [], ok: false),
        Redirect(location: "/a\u{0}b", allowing: [], ok: false),
        Redirect(location: "/a\u{7F}", allowing: [], ok: false),
        Redirect(location: "/a b", allowing: [], ok: false),
        Redirect(location: "https://fleet.example:9085/x", allowing: ["https://fleet.example:9085"], ok: true),
        Redirect(location: "https://fleet.example:9085", allowing: ["https://fleet.example:9085"], ok: true),
        Redirect(location: "https://fleet.example:9085?x=1", allowing: ["https://fleet.example:9085"], ok: true),
        Redirect(location: "https://fleet.example:9085#top", allowing: ["https://fleet.example:9085"], ok: true),
        Redirect(location: "https://fleet.example:9085.evil.example/", allowing: ["https://fleet.example:9085"], ok: false),
        Redirect(location: "https://fleet.example:9085@evil.example/", allowing: ["https://fleet.example:9085"], ok: false),
        Redirect(location: "ftp://fleet.example:9085/", allowing: ["https://fleet.example:9085"], ok: false),   // another scheme, same host
        Redirect(location: "https://other.example/", allowing: ["https://fleet.example:9085"], ok: false),
    ]

    @Test("A redirect is path-absolute or on a named origin, and nothing else", arguments: redirects)
    func redirectTargets(_ c: Redirect) throws {
        if c.ok {
            let response = try Response.redirect(to: c.location, allowing: c.allowing)
            #expect(response.headers[.location] == c.location)
            #expect(response.status == .found)
        } else {
            #expect(throws: RedirectError.location) { _ = try Response.redirect(to: c.location, allowing: c.allowing) }
        }
    }

    @Test("Only 301, 302, 303, 307 and 308 are redirect statuses", arguments: [
        (301, true), (302, true), (303, true), (307, true), (308, true),
        (200, false), (300, false), (304, false), (305, false), (306, false), (309, false), (404, false),
    ])
    func redirectStatuses(_ pair: (Int, Bool)) throws {
        let status = HTTPResponse.Status(code: pair.0)
        if pair.1 {
            #expect(try Response.redirect(to: "/x", status: status).status == status)
        } else {
            #expect(throws: RedirectError.status) { _ = try Response.redirect(to: "/x", status: status) }
        }
    }

    // MARK: Cookies

    @Test("The defaults are the safe ones: Secure, HttpOnly, SameSite=Lax, Path=/")
    func cookieDefaults() throws {
        #expect(try Cookie(name: "sid", value: "abc").headerValue == "sid=abc; Path=/; Secure; HttpOnly; SameSite=Lax")
    }

    @Test("Every attribute is written, in a fixed order")
    func cookieAttributes() throws {
        let cookie = try Cookie(name: "sid", value: "abc", maxAge: 3600, path: "/app", domain: "example.com",
                                secure: true, httpOnly: false, sameSite: .strict)
        #expect(cookie.headerValue == "sid=abc; Max-Age=3600; Path=/app; Domain=example.com; Secure; SameSite=Strict")
    }

    struct BadCookie: Sendable, CustomTestStringConvertible {
        let name: String
        let build: @Sendable () throws -> Cookie
        let error: CookieError
        var testDescription: String { name }
    }

    static let badCookies: [BadCookie] = [
        BadCookie(name: "empty name", build: { try Cookie(name: "", value: "v") }, error: .name),
        BadCookie(name: "name with =", build: { try Cookie(name: "a=b", value: "v") }, error: .name),
        BadCookie(name: "name with space", build: { try Cookie(name: "a b", value: "v") }, error: .name),
        BadCookie(name: "name with ;", build: { try Cookie(name: "a;b", value: "v") }, error: .name),
        BadCookie(name: "name with newline", build: { try Cookie(name: "a\nb", value: "v") }, error: .name),
        BadCookie(name: "value with ;", build: { try Cookie(name: "a", value: "x;y") }, error: .value),
        BadCookie(name: "value with ,", build: { try Cookie(name: "a", value: "x,y") }, error: .value),
        BadCookie(name: "value with space", build: { try Cookie(name: "a", value: "x y") }, error: .value),
        BadCookie(name: "value with quote", build: { try Cookie(name: "a", value: "x\"y") }, error: .value),
        BadCookie(name: "value with backslash", build: { try Cookie(name: "a", value: "x\\y") }, error: .value),
        BadCookie(name: "value with CRLF", build: { try Cookie(name: "a", value: "x\r\nSet-Cookie: b=1") }, error: .value),
        BadCookie(name: "value with DEL", build: { try Cookie(name: "a", value: "x\u{7F}y") }, error: .value),
        BadCookie(name: "value with a tab", build: { try Cookie(name: "a", value: "x\ty") }, error: .value),
        BadCookie(name: "value with non-ASCII", build: { try Cookie(name: "a", value: "caf\u{E9}") }, error: .value),
        BadCookie(name: "negative Max-Age", build: { try Cookie(name: "a", value: "v", maxAge: -1) }, error: .maxAge),
        BadCookie(name: "Max-Age over 400 days", build: { try Cookie(name: "a", value: "v", maxAge: 34_560_001) }, error: .maxAge),
        BadCookie(name: "path with ;", build: { try Cookie(name: "a", value: "v", path: "/a;b") }, error: .path),
        BadCookie(name: "path not starting with /", build: { try Cookie(name: "a", value: "v", path: "a") }, error: .path),
        BadCookie(name: "empty domain", build: { try Cookie(name: "a", value: "v", domain: "") }, error: .domain),
        BadCookie(name: "domain with space", build: { try Cookie(name: "a", value: "v", domain: "a b") }, error: .domain),
        BadCookie(name: "domain with ;", build: { try Cookie(name: "a", value: "v", domain: "a;b") }, error: .domain),
        BadCookie(name: "SameSite=None without Secure", build: { try Cookie(name: "a", value: "v", secure: false, sameSite: .none) }, error: .sameSite),
        BadCookie(name: "__Host- without Secure", build: { try Cookie(name: "__Host-a", value: "v", secure: false) }, error: .prefix),
        BadCookie(name: "__Host- with a Domain", build: { try Cookie(name: "__Host-a", value: "v", domain: "example.com") }, error: .prefix),
        BadCookie(name: "__Host- with another Path", build: { try Cookie(name: "__Host-a", value: "v", path: "/app") }, error: .prefix),
        BadCookie(name: "__Secure- without Secure", build: { try Cookie(name: "__Secure-a", value: "v", secure: false) }, error: .prefix),
    ]

    @Test("A cookie that could be misread, or that breaks its prefix's rules, is refused", arguments: badCookies)
    func cookieRefusals(_ c: BadCookie) {
        #expect(throws: c.error) { _ = try c.build() }
    }

    @Test("The edges are accepted: Max-Age 0 and 400 days, __Host- done right, SameSite=None with Secure")
    func cookieEdges() throws {
        #expect(try Cookie(name: "a", value: "v", maxAge: 0).headerValue.contains("Max-Age=0"))
        #expect(try Cookie(name: "a", value: "v", maxAge: 34_560_000).headerValue.contains("Max-Age=34560000"))
        #expect(try Cookie(name: "__Host-a", value: "v").headerValue == "__Host-a=v; Path=/; Secure; HttpOnly; SameSite=Lax")
        #expect(try Cookie(name: "a", value: "v", sameSite: .none).headerValue.hasSuffix("SameSite=None"))
        #expect(try Cookie(name: "a", value: "").headerValue.hasPrefix("a=;"))
    }

    @Test("Setting cookies appends a Set-Cookie each and never replaces another")
    func setCookieAppends() throws {
        let response = Response.empty(.ok)
            .setting(cookie: try Cookie(name: "a", value: "1"))
            .setting(cookie: try Cookie(name: "b", value: "2"))
        #expect(response.headers[values: .setCookie].count == 2)
        #expect(response.headers[values: .setCookie].map { $0.prefix(3) } == ["a=1", "b=2"])
    }

    // MARK: Reading cookies

    private static func request(cookies: [String]) throws -> Request {
        var headers = HTTPFields()
        for value in cookies { headers.append(HTTPField(name: .cookie, value: value)) }
        return try Request(method: .get, target: "/x", headers: headers, body: Data())
    }

    @Test("Cookie pairs are read in order; a malformed pair is skipped and never throws")
    func readCookies() throws {
        let request = try Self.request(cookies: ["a=1; b=2;c=3", "d=4"])
        #expect(request.cookies.map(\.name) == ["a", "b", "c", "d"])
        #expect(request.cookies.map(\.value) == ["1", "2", "3", "4"])
        let messy = try Self.request(cookies: ["=x; novalue; ok=1; ;  spaced = no; q=\"quoted\"; empty="])
        #expect(messy.cookies.map(\.name) == ["ok", "q", "empty"])
        #expect(messy.cookies.map(\.value) == ["1", "quoted", ""])
    }

    @Test("The first cookie of a name is the one found; duplicates are all kept")
    func firstCookie() throws {
        let request = try Self.request(cookies: ["a=1; a=2"])
        #expect(request.cookie(named: "a") == "1")
        #expect(request.cookies.count == 2)
        #expect(request.cookie(named: "missing") == nil)
    }
}
