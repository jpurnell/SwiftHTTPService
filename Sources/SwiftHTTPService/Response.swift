// Response.swift
// SwiftHTTPService
//
// A response, as a handler builds it.

import Foundation
import HTTPTypes

/// An HTTP response: a status, header fields and a body.
///
/// The transport adds `Content-Length`, `Date` and `Connection`; a handler sets only what is its own.
public struct Response: Sendable, Equatable {
    /// The status.
    public var status: HTTPResponse.Status
    /// The header fields.
    public var headers: HTTPFields
    /// The body. Empty for a response that has none.
    public var body: Data

    /// Creates a response.
    public init(status: HTTPResponse.Status, headers: HTTPFields = HTTPFields(), body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// The encoder ``json(_:status:encoder:)`` uses unless given one: keys sorted, slashes unescaped, dates
    /// as ISO 8601. Sorted keys are what make a body the same bytes every time, which an `ETag` relies on.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// A JSON response.
    public static func json<Value: Encodable>(
        _ value: Value, status: HTTPResponse.Status = .ok, encoder: JSONEncoder = Response.makeEncoder()
    ) throws -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(status: status, headers: headers, body: try encoder.encode(value))
    }

    /// A response with a status and nothing else.
    public static func empty(_ status: HTTPResponse.Status) -> Response {
        Response(status: status)
    }

    /// `304 Not Modified`, carrying the entity tag the client already holds.
    public static func notModified(etag: String) -> Response {
        var headers = HTTPFields()
        headers[.eTag] = etag
        return Response(status: .notModified, headers: headers)
    }

    /// An RFC 9457 problem response.
    ///
    /// Throws only if encoding fails, which a problem's members (strings and an integer) cannot cause. It
    /// is declared so the impossible case reaches the transport as a `500` instead of being swallowed.
    public static func problem(_ problem: Problem) throws -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "application/problem+json"
        return Response(status: problem.httpStatus, headers: headers, body: try Response.makeEncoder().encode(problem))
    }

    /// A copy with one header field set, replacing any earlier value.
    public func setting(_ name: HTTPField.Name, to value: String) -> Response {
        var copy = self
        copy.headers[name] = value
        return copy
    }

    /// A copy with `Retry-After` set, in whole seconds.
    public func retrying(after seconds: Int) -> Response {
        setting(.retryAfter, to: String(seconds))
    }
}
