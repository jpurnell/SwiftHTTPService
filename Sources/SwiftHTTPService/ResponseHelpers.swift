// ResponseHelpers.swift
// SwiftHTTPService
//
// Typed bodies and redirects, with the headers that make them safe to send.

import Foundation
import HTTPTypes

/// A redirect that was refused. It never carries the location.
public enum RedirectError: Error, Equatable, Sendable {
    /// The location is not a path-absolute reference or an allowed origin, or holds a character that could
    /// split a response or be read two ways.
    case location
    /// The status is not one of 301, 302, 303, 307 and 308.
    case status
    /// An entry of `allowing` is not `scheme://host[:port]`: a misconfiguration, refused whatever the location is.
    case origin
}

private enum SafetyHeader {
    /// `X-Content-Type-Options`, which tells a browser to believe the `Content-Type` and not to guess.
    static let noSniff: HTTPField.Name = {
        // A constant that is a valid field name; if a change ever makes it invalid, every test fails at once.
        guard let name = HTTPField.Name("X-Content-Type-Options") else { preconditionFailure("a valid field name") }
        return name
    }()
}

extension Response {

    private static func typed(_ contentType: String, _ body: Data, status: HTTPResponse.Status, cacheControl: String?) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = contentType
        headers[SafetyHeader.noSniff] = "nosniff"
        if let cacheControl { headers[.cacheControl] = cacheControl }
        return Response(status: status, headers: headers, body: body)
    }

    /// An HTML page, `text/html; charset=utf-8`, with `nosniff`.
    public static func html(_ text: String, status: HTTPResponse.Status = .ok, cacheControl: String? = nil) -> Response {
        typed("text/html; charset=utf-8", Data(text.utf8), status: status, cacheControl: cacheControl)
    }

    /// Plain text, `text/plain; charset=utf-8`, with `nosniff`.
    public static func text(_ text: String, status: HTTPResponse.Status = .ok, cacheControl: String? = nil) -> Response {
        typed("text/plain; charset=utf-8", Data(text.utf8), status: status, cacheControl: cacheControl)
    }

    /// A script, `text/javascript; charset=utf-8`, with `nosniff`.
    public static func javascript(_ text: String, status: HTTPResponse.Status = .ok, cacheControl: String? = nil) -> Response {
        typed("text/javascript; charset=utf-8", Data(text.utf8), status: status, cacheControl: cacheControl)
    }

    /// A stylesheet, `text/css; charset=utf-8`, with `nosniff`.
    public static func css(_ text: String, status: HTTPResponse.Status = .ok, cacheControl: String? = nil) -> Response {
        typed("text/css; charset=utf-8", Data(text.utf8), status: status, cacheControl: cacheControl)
    }

    /// A PNG image, `image/png`, with `nosniff`. The bytes are the caller's; they are not inspected.
    public static func png(_ data: Data, status: HTTPResponse.Status = .ok, cacheControl: String? = nil) -> Response {
        typed("image/png", data, status: status, cacheControl: cacheControl)
    }

    /// A redirect that cannot leave the site by accident.
    ///
    /// `location` must be a path-absolute reference (`/x?y=z`): visible ASCII, starting with a single `/`, no
    /// backslash (browsers read it as a slash) and no space or control character (response splitting). A
    /// reference to another site is accepted only if it is on one of `origins`, matched whole: the character after
    /// the origin must be `/`, `?`, `#` or the end, so `https://a.example` does not admit `https://a.example.evil`
    /// or `https://a.example@evil`. A redirect built from a request's input is therefore never an open redirect.
    ///
    /// - Parameters:
    ///   - location: Where to go.
    ///   - status: 301, 302, 303, 307 or 308. Default 302.
    ///   - origins: Origins that may be redirected to, as `http` or `https` `://host[:port]` with no path, no trailing
    ///     slash, no user information. The host is a name or a bracketed IPv6 literal.
    /// - Throws: ``RedirectError``, which never carries the location. An entry of `origins` that is not an origin
    ///   is `.origin`, even if the location would not have matched it: `"https:"` would admit every https address.
    public static func redirect(
        to location: String, status: HTTPResponse.Status = .found, allowing origins: [String] = []
    ) throws(RedirectError) -> Response {
        guard [301, 302, 303, 307, 308].contains(status.code) else { throw .status }
        guard origins.allSatisfy(isOrigin) else { throw .origin }
        guard isSafeLocation(location, origins: origins) else { throw .location }
        var headers = HTTPFields()
        headers[.location] = location
        return Response(status: status, headers: headers)
    }

    /// `http://` or `https://`, a host (a DNS name, or an IPv6 literal in brackets) and an optional `:port`, and nothing more.
    private static func isOrigin(_ text: String) -> Bool {
        let authority: Substring
        if text.hasPrefix("https://") { authority = text.dropFirst(8) } else if text.hasPrefix("http://") { authority = text.dropFirst(7) } else { return false }
        var host = authority
        var port: Substring?
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return false }
            host = authority[authority.startIndex...close]
            let rest = authority[authority.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":") else { return false }
                port = rest.dropFirst()
            }
            let inner = host.dropFirst().dropLast()
            guard inner.contains(":"), inner.utf8.allSatisfy({ $0 == 0x3A || $0 == 0x2E || ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x46) || ($0 >= 0x61 && $0 <= 0x66) }) else { return false }
        } else {
            let parts = authority.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            host = parts[0]
            if parts.count == 2 { port = parts[1] }
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            guard !host.isEmpty, labels.allSatisfy({ label in
                !label.isEmpty && label.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D }
            }) else { return false }
        }
        guard let port else { return true }
        return (1...5).contains(port.count) && port.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } && (Int(port) ?? 65_536) <= 65_535
    }

    private static func isSafeLocation(_ location: String, origins: [String]) -> Bool {
        let bytes = Array(location.utf8)
        guard !bytes.isEmpty, bytes.allSatisfy({ $0 > 0x20 && $0 < 0x7F && $0 != 0x5C }) else { return false }
        if bytes[0] == 0x2F {                       // "/"
            return bytes.count == 1 || bytes[1] != 0x2F
        }
        return origins.contains { origin in
            guard location.hasPrefix(origin) else { return false }
            let rest = location.dropFirst(origin.count)
            guard let next = rest.first else { return true }
            return next == "/" || next == "?" || next == "#"
        }
    }
}
