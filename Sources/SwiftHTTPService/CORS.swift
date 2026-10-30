// CORS.swift
// SwiftHTTPService
//
// Cross-origin requests from a browser, strictly: a list of origins, echoed, never a wildcard.

import Foundation
import HTTPTypes

/// A CORS configuration that was refused. It names a position or a field and never a value.
public enum CORSError: Error, Equatable, Sendable {
    /// The origin at this position is not a serialized origin, `scheme://host[:port]`, written as a browser writes it:
    /// `*`, `null`, a path, query or fragment, userinfo, an upper-case letter, whitespace or a control character,
    /// a malformed port, or an explicit default port (`:80` for `http`, `:443` for `https`, which a browser never sends).
    case invalidOrigin(at: Int)
    /// `allowedMethods` is empty or holds something that is not an HTTP token.
    case invalidMethods
    /// `allowedHeaders` is empty or holds something that is not an HTTP token.
    case invalidHeaders
}

/// Lets a browser page from a listed origin call this server, and refuses every other origin.
///
/// The rule, in order:
/// 1. A request with **no** `Origin` passes through untouched.
/// 2. An `Origin` that is not on the list (compared byte for byte, so `HTTPS://app.example` and `https://app.example/`
///    are not `https://app.example`), or a request with more than one `Origin`, is answered `403` as a problem with
///    the code `origin_not_allowed`. The handler is not run. This includes a same-origin `POST` from a browser, which
///    sends its own origin: list it.
/// 3. An `OPTIONS` request from a listed origin is a preflight and is answered **here**, `204` with
///    `Access-Control-Allow-Methods` and `Access-Control-Allow-Headers`, for any path, **without calling `next`**.
/// 4. Any other request from a listed origin goes to the handler, and its response, success or the handler's own
///    error, carries `Access-Control-Allow-Origin` with that one origin echoed. There is never a wildcard.
///
/// With a non-empty list every response this layer returns, including the refusal and a response from the handler,
/// carries `Vary: Origin` (added beside the handler's own `Vary`, and not repeated), because the answer depends on the
/// request's `Origin` and a cache must know. With an empty list no origin is allowed, there is no `Vary`, and a request
/// that names an origin is refused.
///
/// A streaming response gets the same headers: they are fields of the ``Response``, sent before the first byte.
/// An error the handler *throws* has no response to carry them, so the transport's `500` has none, as with
/// ``requestID(header:generate:)``.
///
/// **Where it goes in a middleware list.** Before authentication: a preflight carries no credential by design, so an
/// authentication layer that sees it answers `401` and the browser gives up. After ``allowedHosts(_:)`` (a request for a
/// name nobody listed should never reach a preflight) and after logging, so the log sees the refusals. A refusal by a
/// layer further in (a `401`) comes back through this one and carries the headers, which is what lets the page read it.
///
/// - Parameters:
///   - allowedOrigins: Serialized origins such as `https://app.example` or `http://localhost:5173`.
///   - allowedMethods: Tokens for `Access-Control-Allow-Methods`. Default `POST`.
///   - allowedHeaders: Tokens for `Access-Control-Allow-Headers`. Default `Authorization, Content-Type`.
/// - Throws: ``CORSError`` for the first problem found: origins in order, then methods, then headers.
public func cors(
    allowedOrigins: [String], allowedMethods: [String] = ["POST"], allowedHeaders: [String] = ["Authorization", "Content-Type"]
) throws(CORSError) -> Middleware {
    var permitted = Set<[UInt8]>()
    for (index, entry) in allowedOrigins.enumerated() {
        let bytes = Array(entry.utf8)
        guard isSerializedOrigin(bytes) else { throw .invalidOrigin(at: index) }
        permitted.insert(bytes)
    }
    guard !allowedMethods.isEmpty, allowedMethods.allSatisfy({ isToken($0) }) else { throw .invalidMethods }
    guard !allowedHeaders.isEmpty, allowedHeaders.allSatisfy({ isToken($0) }) else { throw .invalidHeaders }
    let allowed = permitted
    let varies = !allowed.isEmpty
    let methods = allowedMethods.joined(separator: ", ")
    let headers = allowedHeaders.joined(separator: ", ")
    return { request, next in
        let origins = request.headers[values: .origin]
        guard let origin = origins.first else {
            return addVary(to: try await next(request), if: varies)
        }
        guard origins.count == 1, allowed.contains(Array(origin.utf8)) else {
            let refusal = try Response.problem(Problem(status: .forbidden, code: "origin_not_allowed"))
            return addVary(to: refusal, if: varies)
        }
        if request.method == .options {
            var preflight = Response(status: .noContent)
            preflight.headers[.accessControlAllowOrigin] = origin
            preflight.headers[.accessControlAllowMethods] = methods
            preflight.headers[.accessControlAllowHeaders] = headers
            return addVary(to: preflight, if: varies)
        }
        var response = try await next(request)
        response.headers[.accessControlAllowOrigin] = origin
        return addVary(to: response, if: varies)
    }
}

/// Adds `Vary: Origin` unless the response already varies on `Origin` or on everything.
private func addVary(to response: Response, if applies: Bool) -> Response {
    guard applies else { return response }
    var response = response
    let existing = response.headers[values: .vary]
    let covered = existing.contains { value in
        value.split(separator: ",").contains { token in
            let name = token.trimmingCharacters(in: .whitespaces).lowercased()
            return name == "origin" || name == "*"
        }
    }
    if !covered { response.headers.append(HTTPField(name: .vary, value: "Origin")) }
    return response
}

/// `scheme://host[:port]` in lower case, with a port that is not the scheme's default.
private func isSerializedOrigin(_ bytes: [UInt8]) -> Bool {
    guard !bytes.contains(where: { $0 >= 0x41 && $0 <= 0x5A }) else { return false }
    let separator = Array("://".utf8)
    guard let at = firstIndex(of: separator, in: bytes) else { return false }
    let scheme = bytes[..<at]
    let authority = Array(bytes[(at + separator.count)...])
    guard let first = scheme.first, first >= 0x61, first <= 0x7A else { return false }
    guard scheme.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2B || $0 == 0x2D || $0 == 0x2E }) else {
        return false
    }
    guard HostSyntax.isHostWithOptionalPort(authority) else { return false }
    // A browser leaves the default port out, so an entry that spells it could never match.
    let defaultPort: [String: String] = ["http": "80", "https": "443"]
    if let port = trailingPort(of: authority), defaultPort[String(decoding: scheme, as: UTF8.self)] == port { return false }
    return true
}

private func trailingPort(of authority: [UInt8]) -> String? {
    guard let colon = authority.lastIndex(of: UInt8(ascii: ":")) else { return nil }
    // After a bracketed literal the tail ends in `]`, so it can never equal a default port.
    return String(decoding: authority[(colon + 1)...], as: UTF8.self)
}

private func firstIndex(of pattern: [UInt8], in bytes: [UInt8]) -> Int? {
    guard bytes.count >= pattern.count else { return nil }
    return (0...(bytes.count - pattern.count)).first { bytes[$0..<($0 + pattern.count)].elementsEqual(pattern) }
}

/// An HTTP token (RFC 9110 section 5.6.2): what a method or a field name is made of.
private func isToken(_ text: String) -> Bool {
    let bytes = text.utf8
    guard !bytes.isEmpty else { return false }
    return bytes.allSatisfy { byte in
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
            || "!#$%&'*+-.^_`|~".utf8.contains(byte)
    }
}
