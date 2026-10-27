import Foundation
import HTTPTypes
import Testing
@testable import SwiftHTTPService

@Suite("Response")
struct ResponseTests {

    private struct Sample: Encodable { let name: String; let count: Int; let at: Date }

    @Test("A JSON response has its status, a JSON content type and the encoded body")
    func json() throws {
        let response = try Response.json(["b": 2, "a": 1])
        #expect(response.status == .ok)
        #expect(response.headers[.contentType] == "application/json")
        #expect(String(decoding: response.body, as: UTF8.self) == #"{"a":1,"b":2}"#)  // keys sorted, by hand
    }

    @Test("A JSON response can carry another status")
    func jsonStatus() throws {
        #expect(try Response.json(["ok": true], status: .created).status == .created)
    }

    @Test("Dates are ISO 8601 and slashes are not escaped")
    func jsonFormats() throws {
        let response = try Response.json(Sample(name: "a/b", count: 1, at: Date(timeIntervalSince1970: 0)))
        #expect(String(decoding: response.body, as: UTF8.self) == #"{"at":"1970-01-01T00:00:00Z","count":1,"name":"a/b"}"#)
    }

    @Test("The same value always encodes to the same bytes")
    func jsonIsDeterministic() throws {
        let value = ["z": 1, "y": 2, "x": 3, "w": 4]
        let first = try Response.json(value).body
        for _ in 0..<20 { #expect(try Response.json(value).body == first) }
    }

    @Test("An encoder can be supplied")
    func customEncoder() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        struct Wire: Encodable { let someKey: Int }
        let response = try Response.json(Wire(someKey: 1), encoder: encoder)
        #expect(String(decoding: response.body, as: UTF8.self) == #"{"some_key":1}"#)
    }

    @Test("An empty response has a status and no body, and no content type")
    func empty() {
        let response = Response.empty(.noContent)
        #expect(response.status == .noContent)
        #expect(response.body.isEmpty)
        #expect(response.headers[.contentType] == nil)
    }

    @Test("Not modified carries the entity tag and no body")
    func notModified() {
        let response = Response.notModified(etag: "\"abc\"")
        #expect(response.status == .notModified)
        #expect(response.headers[.eTag] == "\"abc\"")
        #expect(response.body.isEmpty)
    }

    @Test("A header can be added to a response without changing the original")
    func withHeader() {
        let original = Response.empty(.ok)
        let changed = original.setting(.cacheControl, to: "no-store")
        #expect(changed.headers[.cacheControl] == "no-store")
        #expect(original.headers[.cacheControl] == nil)
    }
}

@Suite("Problem details")
struct ProblemTests {

    @Test("A problem has the RFC 9457 members, a stable code, and a problem+json content type")
    func shape() throws {
        let response = try Response.problem(Problem(status: .unauthorized, code: "unauthorized"))
        #expect(response.status == .unauthorized)
        #expect(response.headers[.contentType] == "application/problem+json")
        // Sorted keys, worked out by hand: code, status, title, type.
        #expect(String(decoding: response.body, as: UTF8.self) == #"{"code":"unauthorized","status":401,"title":"Unauthorized","type":"about:blank"}"#)
    }

    @Test("A detail is sent only when there is one")
    func detail() throws {
        let with = try Response.problem(Problem(status: .serviceUnavailable, code: "computing", detail: "Still running."))
        #expect(String(decoding: with.body, as: UTF8.self).contains(#""detail":"Still running.""#))
        let without = try Response.problem(Problem(status: .notFound, code: "not_found"))
        #expect(!String(decoding: without.body, as: UTF8.self).contains("detail"))
    }

    @Test("A title can replace the status's reason phrase")
    func title() throws {
        let response = try Response.problem(Problem(status: .notFound, code: "not_found", title: "Nothing here"))
        #expect(String(decoding: response.body, as: UTF8.self).contains(#""title":"Nothing here""#))
    }

    @Test("Two problems with the same inputs are the same bytes, so refusals can be made indistinguishable")
    func identicalBytes() throws {
        let a = try Response.problem(Problem(status: .notFound, code: "not_found"))
        let b = try Response.problem(Problem(status: .notFound, code: "not_found"))
        #expect(a == b)
        #expect(a.body == b.body)
    }

    @Test("A retry-after header can be added in whole seconds")
    func retryAfter() throws {
        let response = try Response.problem(Problem(status: .tooManyRequests, code: "rate_limited")).retrying(after: 30)
        #expect(response.headers[.retryAfter] == "30")
    }

    @Test("The status code is carried as a number")
    func statusNumber() throws {
        let object = try #require(JSONSerialization.jsonObject(with: try Response.problem(Problem(status: .notFound, code: "x")).body) as? [String: Any])
        #expect(object["status"] as? Int == 404)
    }
}
