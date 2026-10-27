// Conditional.swift
// SwiftHTTPService
//
// Entity tags and If-None-Match (RFC 9110 sections 8.8.3 and 13.1.2).

import Foundation
import HTTPTypes

/// An entity tag: an opaque validator for one version of a representation.
public struct EntityTag: Sendable, Equatable {
    /// Whether the tag is weak (`W/"..."`).
    public let isWeak: Bool
    /// The text between the quotes.
    public let opaque: String

    /// Creates a tag, or nil if `opaque` could not be written between quotes: it may hold printable ASCII
    /// except a quote and a space.
    public init?(opaque: String, isWeak: Bool) {
        guard opaque.utf8.allSatisfy({ $0 == 0x21 || ($0 >= 0x23 && $0 <= 0x7E) }) else { return nil }
        self.opaque = opaque
        self.isWeak = isWeak
    }

    /// The tag as it is written in a header.
    public var headerValue: String { (isWeak ? "W/" : "") + "\"" + opaque + "\"" }
}

/// Conditional requests: answering `304 Not Modified` when the client already holds the current version.
public enum Conditional {

    /// Whether an `If-None-Match` value matches `current`, by weak comparison (RFC 9110 section 8.8.3.2):
    /// the `W/` prefix is ignored and the quoted text must be equal, byte for byte.
    ///
    /// The value is `*` or a comma-separated list of entity tags. Empty list elements are ignored, as the
    /// RFC requires of a recipient. A value that does not parse, anywhere, matches nothing: the caller sends
    /// the full response, which is always safe, instead of a `304` on a guess.
    public static func ifNoneMatch(_ value: String, matches current: EntityTag) -> Bool {
        let bytes = Array(value.utf8)
        var index = 0
        func skipSpace() { while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 { index += 1 } }

        skipSpace()
        if trimmedEnd(bytes, from: index).elementsEqual("*".utf8) { return true }

        let wanted = Array(current.opaque.utf8)
        var matched = false
        // Each pass consumes at least one byte, so the loop ends within `bytes.count` passes.
        while index < bytes.count {
            skipSpace()
            guard index < bytes.count else { break }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }

            if bytes[index] == UInt8(ascii: "W") {
                guard index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "/") else { return false }
                index += 2
            }
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { return false }
            index += 1
            let start = index
            while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
                let byte = bytes[index]
                guard byte == 0x21 || (byte >= 0x23 && byte <= 0x7E) || byte >= 0x80 else { return false }
                index += 1
            }
            guard index < bytes.count else { return false }          // unterminated
            if bytes[start..<index].elementsEqual(wanted) { matched = true }
            index += 1                                               // the closing quote

            skipSpace()
            guard index == bytes.count || bytes[index] == UInt8(ascii: ",") else { return false }
        }
        return matched
    }

    /// Answers a `GET` or `HEAD` conditionally.
    ///
    /// If the request's `If-None-Match` matches `etag`, the answer is `304` carrying the tag and `produce` is
    /// never called, so the work of building the representation is skipped. Otherwise `produce` runs and the
    /// response carries the tag (unless it already set one). Other methods are not made conditional.
    public static func respond(
        to request: Request, etag: EntityTag, produce: () async throws -> Response
    ) async throws -> Response {
        if request.method == .get || request.method == .head {
            let values = request.headers[values: .ifNoneMatch]
            if !values.isEmpty, ifNoneMatch(values.joined(separator: ","), matches: etag) {
                return .notModified(etag: etag.headerValue)
            }
        }
        var response = try await produce()
        if response.headers[.eTag] == nil { response.headers[.eTag] = etag.headerValue }
        return response
    }

    private static func trimmedEnd(_ bytes: [UInt8], from start: Int) -> ArraySlice<UInt8> {
        var end = bytes.count
        while end > start, bytes[end - 1] == 0x20 || bytes[end - 1] == 0x09 { end -= 1 }
        return bytes[start..<end]
    }
}
