import Foundation
import HTTPTypes
import Testing
@testable import SwiftHTTPService

/// The secure-by-default header policy, as a pure function of a response and whether the server serves TLS.
/// Expected values are the literals in `project/plans/proposals/SecurityHeaders.md` section 4.1, not read back from the code.
@Suite("Response header policy")
struct ResponseHeaderPolicyTests {

    // MARK: Fixtures

    private struct Missing: Error {}

    private static func name(_ text: String) throws -> HTTPField.Name {
        guard let name = HTTPField.Name(text) else { throw Missing() }
        return name
    }

    private static func response(
        _ status: HTTPResponse.Status = .ok, type: String? = nil, body: String = "", fields: [(String, String)] = []
    ) throws -> Response {
        var headers = HTTPFields()
        if let type { headers[.contentType] = type }
        for (field, value) in fields { headers[try name(field)] = value }
        return Response(status: status, headers: headers, body: Data(body.utf8))
    }

    private static func values(_ response: Response, _ field: String) throws -> [String] {
        Array(response.headers[values: try name(field)])
    }

    private static let jsonCSP = "default-src 'none'; frame-ancestors 'none'"

    // MARK: The defaults

    @Test("A JSON response gains every default, with the values the proposal's table gives")
    func jsonGainsEveryDefault() throws {
        let out = ResponseHeaderPolicy.secure.applying(to: try Self.response(type: "application/json", body: "{}"), overTLS: false)
        #expect(try Self.values(out, "x-content-type-options") == ["nosniff"])
        #expect(try Self.values(out, "cache-control") == ["no-store"])
        #expect(try Self.values(out, "referrer-policy") == ["no-referrer"])
        #expect(try Self.values(out, "x-frame-options") == ["DENY"])
        #expect(try Self.values(out, "content-security-policy") == [Self.jsonCSP])
    }

    @Test("The headers are added to a 404 and a 304 as well: the policy looks at the response, not the route")
    func everyStatus() throws {
        for status in [HTTPResponse.Status.notFound, .notModified, .noContent, .internalServerError, .tooManyRequests] {
            let out = ResponseHeaderPolicy.secure.applying(to: try Self.response(status), overTLS: false)
            #expect(try Self.values(out, "x-content-type-options") == ["nosniff"], "status \(status.code)")
            #expect(try Self.values(out, "cache-control") == ["no-store"], "status \(status.code)")
        }
    }

    // MARK: A handler's own value wins

    @Test("A handler's Cache-Control is kept, not replaced and not repeated")
    func handlerCacheControlWins() throws {
        let input = try Self.response(type: "text/css", body: "a{}", fields: [("Cache-Control", "public, max-age=60")])
        let out = ResponseHeaderPolicy.secure.applying(to: input, overTLS: false)
        #expect(try Self.values(out, "cache-control") == ["public, max-age=60"])
    }

    @Test("The match is on the field name without regard to case: a lower-case handler field is the same field")
    func caseInsensitive() throws {
        let input = try Self.response(type: "application/json", body: "{}", fields: [("cache-control", "no-cache"), ("x-frame-options", "SAMEORIGIN")])
        let out = ResponseHeaderPolicy.secure.applying(to: input, overTLS: false)
        #expect(try Self.values(out, "Cache-Control") == ["no-cache"])
        #expect(try Self.values(out, "X-Frame-Options") == ["SAMEORIGIN"])
    }

    @Test("A handler's own CSP on a JSON response is kept")
    func handlerCSPWins() throws {
        let input = try Self.response(type: "application/json", body: "{}", fields: [("Content-Security-Policy", "default-src 'self'")])
        let out = ResponseHeaderPolicy.secure.applying(to: input, overTLS: false)
        #expect(try Self.values(out, "content-security-policy") == ["default-src 'self'"])
    }

    @Test("A handler's own HSTS is kept over TLS, as FleetWatch's year is")
    func handlerHSTSWins() throws {
        let input = try Self.response(type: "text/html", body: "<p>", fields: [("Strict-Transport-Security", "max-age=31536000")])
        let out = ResponseHeaderPolicy.secure.applying(to: input, overTLS: true)
        #expect(try Self.values(out, "strict-transport-security") == ["max-age=31536000"])
    }

    @Test("Vary is never touched")
    func varyUntouched() throws {
        let input = try Self.response(type: "application/json", body: "{}", fields: [("Vary", "Origin")])
        let out = ResponseHeaderPolicy.secure.applying(to: input, overTLS: false)
        #expect(try Self.values(out, "vary") == ["Origin"])
    }

    @Test("Applying the policy twice changes nothing the second time")
    func idempotent() throws {
        let once = ResponseHeaderPolicy.secure.applying(to: try Self.response(type: "application/json", body: "{}"), overTLS: true)
        let twice = ResponseHeaderPolicy.secure.applying(to: once, overTLS: true)
        #expect(once == twice)
        #expect(try Self.values(twice, "cache-control").count == 1)
    }

    // MARK: The API-only CSP

    @Test("The API CSP goes on JSON, problem+json, any +json type, JSON with parameters, and on an empty body")
    func cspOnApiResponses() throws {
        let cases: [(String?, String)] = [
            ("application/json", "{}"), ("application/problem+json", "{}"), ("application/vnd.x+json", "{}"),
            ("application/json; charset=utf-8", "{}"), (nil, ""), ("text/plain", ""),
        ]
        for (type, body) in cases {
            let out = ResponseHeaderPolicy.secure.applying(to: try Self.response(type: type, body: body), overTLS: false)
            #expect(try Self.values(out, "content-security-policy") == [Self.jsonCSP], "type \(type ?? "none"), body \"\(body)\"")
        }
    }

    @Test("A redirect has an empty body, so it gets the API CSP: pinned so it is deliberate")
    func cspOnRedirect() throws {
        let out = ResponseHeaderPolicy.secure.applying(to: try Self.response(.found, fields: [("Location", "/x")]), overTLS: false)
        #expect(try Self.values(out, "content-security-policy") == [Self.jsonCSP])
    }

    @Test("The API CSP is not put on a page, a stream or an image, which the kit cannot know the needs of")
    func noCspOnOtherTypes() throws {
        for type in ["text/html", "text/html; charset=utf-8", "text/event-stream", "image/png", "text/css", "application/javascript"] {
            let out = ResponseHeaderPolicy.secure.applying(to: try Self.response(type: type, body: "x"), overTLS: false)
            #expect(try Self.values(out, "content-security-policy").isEmpty, "type \(type)")
        }
        let untyped = ResponseHeaderPolicy.secure.applying(to: try Self.response(body: "x"), overTLS: false)
        #expect(try Self.values(untyped, "content-security-policy").isEmpty)
    }

    @Test("X-Frame-Options and nosniff go on a page too: they are not API-only")
    func frameOptionsOnHTML() throws {
        let out = ResponseHeaderPolicy.secure.applying(to: try Self.response(type: "text/html", body: "<p>"), overTLS: false)
        #expect(try Self.values(out, "x-frame-options") == ["DENY"])
        #expect(try Self.values(out, "x-content-type-options") == ["nosniff"])
        #expect(try Self.values(out, "referrer-policy") == ["no-referrer"])
    }

    // MARK: HSTS

    @Test("HSTS is sent over TLS with a 7-day max-age and nothing else, and never over plaintext")
    func hstsOnlyOverTLS() throws {
        let input = try Self.response(type: "application/json", body: "{}")
        let overTLS = ResponseHeaderPolicy.secure.applying(to: input, overTLS: true)
        let plain = ResponseHeaderPolicy.secure.applying(to: input, overTLS: false)
        #expect(try Self.values(overTLS, "strict-transport-security") == ["max-age=604800"])
        #expect(try Self.values(plain, "strict-transport-security").isEmpty)
    }

    @Test("The max-age is in whole seconds, and no value can carry includeSubDomains or preload")
    func hstsValueShape() throws {
        var policy = ResponseHeaderPolicy.secure
        for (duration, seconds) in [(Duration.seconds(86_400), 86_400), (.seconds(30 * 86_400), 2_592_000), (.zero, 0)] {
            policy.hsts = .whenServingTLS(maxAge: duration)
            let out = policy.applying(to: try Self.response(type: "application/json", body: "{}"), overTLS: true)
            #expect(try Self.values(out, "strict-transport-security") == ["max-age=\(seconds)"])
        }
    }

    @Test("HSTS .off sends nothing even over TLS")
    func hstsOff() throws {
        var policy = ResponseHeaderPolicy.secure
        policy.hsts = .off
        let out = policy.applying(to: try Self.response(type: "application/json", body: "{}"), overTLS: true)
        #expect(try Self.values(out, "strict-transport-security").isEmpty)
        #expect(try Self.values(out, "x-content-type-options") == ["nosniff"])
    }

    // MARK: Opting out

    @Test("Opting out needs a reason: a blank one is refused naming responseHeaders.reason")
    func blankReasonRefused() {
        for blank in ["", "   ", "\n\t"] {
            do {
                _ = try ResponseHeaderPolicy.disabled(because: blank)
                Issue.record("a blank reason \"\(blank)\" was accepted")
            } catch {
                #expect(error.field == "responseHeaders.reason")
                #expect(error.reason == .empty)
            }
        }
    }

    @Test("A disabled policy adds nothing, even over TLS, and says why")
    func disabledAddsNothing() throws {
        let policy = try ResponseHeaderPolicy.disabled(because: "behind the vendor's own gateway")
        let input = try Self.response(type: "application/json", body: "{}")
        #expect(policy.applying(to: input, overTLS: true) == input)
        #expect(policy.optOutReason == "behind the vendor's own gateway")
        #expect(ResponseHeaderPolicy.secure.optOutReason == nil)
    }

    @Test("Policies compare by value: the default equals itself, an opt-out is not the default")
    func equality() throws {
        #expect(ResponseHeaderPolicy.secure == ResponseHeaderPolicy.secure)
        #expect(try ResponseHeaderPolicy.disabled(because: "x") != ResponseHeaderPolicy.secure)
    }

    // MARK: The carrier

    @Test("A configuration built the old way carries the default policy; one built with a policy carries that one")
    func configurationCarriesPolicy() throws {
        #expect(try ServiceConfiguration().responseHeaders == .secure)
        let off = try ResponseHeaderPolicy.disabled(because: "test")
        #expect(try ServiceConfiguration(port: 0, responseHeaders: off).responseHeaders == off)
    }
}
