// Cookie.swift
// SwiftHTTPService
//
// Cookies that are hard to get wrong: a typed builder, and a reader that never throws.

import Foundation
import HTTPTypes

/// A cookie that was refused. It names the part and never the value.
public enum CookieError: Error, Equatable, Sendable {
    /// The name is not an RFC 9110 token.
    case name
    /// The value holds a character outside RFC 6265's `cookie-octet` set.
    case value
    /// `Max-Age` is outside 0 to 400 days.
    case maxAge
    /// The path does not start with `/` or holds a character that ends an attribute.
    case path
    /// The domain holds a character other than letters, digits, `.` and `-`.
    case domain
    /// `SameSite=None` without `Secure`, which browsers ignore.
    case sameSite
    /// A `__Host-` or `__Secure-` name that does not meet its prefix's rules.
    case prefix
}

/// A cookie to send in a `Set-Cookie` field.
///
/// The defaults are the safe ones (`Secure`, `HttpOnly`, `SameSite=Lax`, `Path=/`), and the initialiser refuses
/// what a browser would read differently from the server: a value with a semicolon, a comma, a space, a quote
/// or a backslash; `SameSite=None` without `Secure`; a `__Host-` cookie with a `Domain` or a path other than `/`.
public struct Cookie: Sendable, Equatable {
    /// The `SameSite` attribute.
    public enum SameSite: String, Sendable, Hashable {
        /// Never sent with a cross-site request.
        case strict = "Strict"
        /// Sent with a cross-site top-level navigation, not with a cross-site sub-request.
        case lax = "Lax"
        /// Always sent. Requires `Secure`.
        case none = "None"
    }

    /// The name.
    public let name: String
    /// The value, without quotes.
    public let value: String
    /// The `Max-Age` in seconds, if any. Without one the cookie lasts for the browser session.
    public let maxAge: Int?
    /// The `Path`, if any.
    public let path: String?
    /// The `Domain`, if any. Without one the cookie is for the exact host only.
    public let domain: String?
    /// Whether the cookie is sent over HTTPS only.
    public let secure: Bool
    /// Whether script can read the cookie. `true` hides it from script.
    public let httpOnly: Bool
    /// The `SameSite` attribute.
    public let sameSite: SameSite

    /// Creates a cookie.
    ///
    /// - Throws: ``CookieError`` for the first part that is refused. Nothing is clamped or cleaned.
    public init(
        name: String, value: String, maxAge: Int? = nil, path: String? = "/", domain: String? = nil,
        secure: Bool = true, httpOnly: Bool = true, sameSite: SameSite = .lax
    ) throws(CookieError) {
        guard Self.isToken(name) else { throw .name }
        guard value.utf8.allSatisfy(Self.isCookieOctet) else { throw .value }
        if let maxAge { guard (0...34_560_000).contains(maxAge) else { throw .maxAge } }
        if let path { guard path.hasPrefix("/"), path.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F && $0 != 0x3B }) else { throw .path } }
        if let domain {
            guard !domain.isEmpty, domain.utf8.allSatisfy({ Self.isAlphanumeric($0) || $0 == 0x2E || $0 == 0x2D }) else { throw .domain }
        }
        if sameSite == .none, !secure { throw .sameSite }
        if name.hasPrefix("__Host-"), !(secure && path == "/" && domain == nil) { throw .prefix }
        if name.hasPrefix("__Secure-"), !secure { throw .prefix }
        self.name = name
        self.value = value
        self.maxAge = maxAge
        self.path = path
        self.domain = domain
        self.secure = secure
        self.httpOnly = httpOnly
        self.sameSite = sameSite
    }

    /// The field value: `name=value`, then the attributes in a fixed order.
    public var headerValue: String {
        var parts = ["\(name)=\(value)"]
        if let maxAge { parts.append("Max-Age=\(maxAge)") }
        if let path { parts.append("Path=\(path)") }
        if let domain { parts.append("Domain=\(domain)") }
        if secure { parts.append("Secure") }
        if httpOnly { parts.append("HttpOnly") }
        parts.append("SameSite=\(sameSite.rawValue)")
        return parts.joined(separator: "; ")
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }

    /// RFC 9110 `token`: one or more of ``!#$%&'*+-.^_`|~`` and letters and digits.
    static func isToken(_ text: String) -> Bool {
        let bytes = text.utf8
        guard !bytes.isEmpty else { return false }
        let others = Set("!#$%&'*+-.^_`|~".utf8)
        return bytes.allSatisfy { isAlphanumeric($0) || others.contains($0) }
    }

    /// RFC 6265 `cookie-octet`: 0x21, 0x23-0x2B, 0x2D-0x3A, 0x3C-0x5B, 0x5D-0x7E.
    private static func isCookieOctet(_ byte: UInt8) -> Bool {
        byte == 0x21 || (0x23...0x2B).contains(byte) || (0x2D...0x3A).contains(byte)
            || (0x3C...0x5B).contains(byte) || (0x5D...0x7E).contains(byte)
    }
}

/// One `name=value` pair read from a request's `Cookie` header.
public struct CookiePair: Sendable, Equatable {
    /// The name.
    public let name: String
    /// The value, with a surrounding pair of quotes removed.
    public let value: String
}

extension Response {
    /// A copy with a `Set-Cookie` field added. Earlier `Set-Cookie` fields are kept: each cookie is its own field.
    public func setting(cookie: Cookie) -> Response {
        var copy = self
        copy.headers.append(HTTPField(name: .setCookie, value: cookie.headerValue))
        return copy
    }
}

extension Request {
    /// The cookies the client sent, in order.
    ///
    /// Read leniently and never throwing: a pair with no `=`, an empty name or a name that is not a token is
    /// skipped, and the rest are kept. Several `Cookie` fields (HTTP/2 splits them) are read as one list.
    public var cookies: [CookiePair] {
        headers[values: .cookie].flatMap { line in
            line.split(separator: ";", omittingEmptySubsequences: true).compactMap { piece -> CookiePair? in
                let trimmed = piece.drop(while: { $0 == " " || $0 == "\t" })
                guard let equals = trimmed.firstIndex(of: "=") else { return nil }
                let name = String(trimmed[trimmed.startIndex..<equals])
                guard Cookie.isToken(name) else { return nil }
                var value = String(trimmed[trimmed.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
                if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
                return CookiePair(name: name, value: value)
            }
        }
    }

    /// The value of the first cookie named `name`, or nil.
    public func cookie(named name: String) -> String? {
        cookies.first { $0.name == name }?.value
    }
}
