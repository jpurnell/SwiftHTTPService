import Foundation
import HTTPTypes
import Testing
import SwiftHTTPService
@testable import SwiftHTTPServiceNIO

/// The rules HTTP/1.1 and HTTP/2 share. Expected values are worked out from RFC 9110 and RFC 9112, not read
/// back from the code.
@Suite("Shared request and response rules")
struct SharedRulesTests {

    // MARK: Field values

    @Test("A field value with CR, LF or NUL is not clean; ordinary text, tabs and spaces are")
    func cleanValues() {
        #expect(RequestRules.isCleanFieldValue("text/plain; charset=utf-8"))
        #expect(RequestRules.isCleanFieldValue("a\tb c"))
        #expect(RequestRules.isCleanFieldValue(""))
        #expect(!RequestRules.isCleanFieldValue("a\rb"))
        #expect(!RequestRules.isCleanFieldValue("a\nb"))
        #expect(!RequestRules.isCleanFieldValue("a\u{0}b"))
    }

    // MARK: Bounds

    @Test("A body fits up to and including the bound, and not one byte past it")
    func bodyBound() {
        #expect(RequestRules.bodyFits(received: 6, incoming: 4, limit: 10))
        #expect(!RequestRules.bodyFits(received: 6, incoming: 5, limit: 10))
        #expect(RequestRules.bodyFits(received: 0, incoming: 0, limit: 0))
        #expect(!RequestRules.bodyFits(received: 0, incoming: 1, limit: 0))
    }

    @Test("A declared length fits up to and including the bound")
    func declaredBound() {
        #expect(RequestRules.declaredLengthFits(10, limit: 10))
        #expect(!RequestRules.declaredLengthFits(11, limit: 10))
    }

    // MARK: Targets

    @Test("The core's strict origin-form parse decides the target")
    func targets() {
        #expect(RequestRules.isAcceptableTarget(method: .get, target: "/a/b?c=d", fields: HTTPFields()))
        #expect(!RequestRules.isAcceptableTarget(method: .get, target: "https://x/a", fields: HTTPFields()))
        #expect(!RequestRules.isAcceptableTarget(method: .get, target: "//a", fields: HTTPFields()))
        #expect(!RequestRules.isAcceptableTarget(method: .get, target: "", fields: HTTPFields()))
        // The core refuses what HTTP/2 can carry and HTTP/1.1's parser never delivers: pinned here, since HTTP/2 relies on it.
        #expect(!RequestRules.isAcceptableTarget(method: .get, target: "/a b", fields: HTTPFields()))
        #expect(!RequestRules.isAcceptableTarget(method: .get, target: "/a\tb", fields: HTTPFields()))
        #expect(!RequestRules.isAcceptableTarget(method: .get, target: "/a\u{7F}", fields: HTTPFields()))
        #expect(!RequestRules.isAcceptableTarget(method: .get, target: "/caf\u{E9}", fields: HTTPFields()))
    }

    // MARK: Responses

    @Test("The transport owns Content-Length, Date and the connection fields; the handler's others pass")
    func ownedFields() throws {
        var fields = HTTPFields()
        fields[.contentType] = "application/json"
        fields[.contentLength] = "999"
        fields[.date] = "yesterday"
        fields[.connection] = "upgrade"
        fields[try #require(HTTPField.Name("Keep-Alive"))] = "timeout=5"
        fields[try #require(HTTPField.Name("Transfer-Encoding"))] = "chunked"
        fields[try #require(HTTPField.Name("X-Thing"))] = "1"
        let prepared = ResponseRules.prepare(Response(status: .ok, headers: fields, body: Data("{}".utf8)))
        let names = Set(prepared.fields.map { $0.name.rawName.lowercased() })
        #expect(names == ["content-type", "x-thing"])
    }

    @Test("1xx, 204 and 304 carry no body; other final statuses do (RFC 9110 sections 6.4.1 and 15)", arguments: [
        (100, false), (199, false), (200, true), (204, false), (205, true), (304, false), (404, true), (599, true),
    ])
    func bodyAllowed(_ pair: (Int, Bool)) {
        let response = Response(status: HTTPResponse.Status(code: pair.0), headers: HTTPFields(), body: Data("x".utf8))
        #expect(ResponseRules.prepare(response).hasBody == pair.1)
    }

    @Test("A final status passes; a non-final one or a thrown error becomes an internal error with no text")
    func outcomes() {
        struct Secret: Error, CustomStringConvertible { var description: String { "the database password" } }
        let ok = Response(status: .ok, headers: HTTPFields(), body: Data())
        #expect(ResponseRules.outcome(of: .success(ok)) == .success(ok))
        let informational = Response(status: HTTPResponse.Status(code: 100), headers: HTTPFields(), body: Data())
        #expect(ResponseRules.outcome(of: .success(informational)) == .failure(.internalError))
        #expect(ResponseRules.outcome(of: .failure(Secret())) == .failure(.internalError))
        #expect(!String(decoding: Refusal.internalError.body, as: UTF8.self).contains("password"))
    }

    @Test("A refusal answers as application/problem+json with its fixed body and status", arguments: Refusal.allCases)
    func refusalResponses(_ refusal: Refusal) {
        let response = refusal.response
        #expect(response.status.code == refusal.statusCode)
        #expect(response.headers[.contentType] == "application/problem+json")
        #expect(response.body == refusal.body)
    }
}
