// AllowedHosts.swift
// SwiftHTTPService
//
// Refuses a request for a name nobody listed: the defence against DNS rebinding on a loopback bind.

import Foundation
import HTTPTypes

/// An allow-list of hosts that was refused. It names a position and never a value.
public enum AllowedHostsError: Error, Equatable, Sendable {
    /// The list is empty: a server that admits no host admits no request.
    case noEntries
    /// The entry at this position is not a bare `host` or `host:port`: it is empty, holds whitespace, a control
    /// character or any byte outside visible ASCII, a scheme, a path, a query, userinfo, or a wildcard, or its port
    /// or bracketed IPv6 literal is malformed.
    case invalidEntry(at: Int)
}

/// Answers `421 Misdirected Request` unless the request's `Host` is on the list. The handler is not run for a refusal.
///
/// **This is for a bind on loopback.** A web page on `evil.example` can be made to resolve to `127.0.0.1` (DNS
/// rebinding) and then talk to a server that trusts everything on the loopback interface; its requests still carry
/// `Host: evil.example`, which this refuses. Over HTTP/2 the transport has already put `:authority` in `Host`, so one
/// check serves both. On a public bind the TLS name plus a `Host` check is the caller's decision: a certificate
/// already ties the connection to a name, and a list that disagrees with the certificate's names is a way to
/// lock yourself out.
///
/// The comparison is on the whole header value, exactly, with ASCII case ignored (and only ASCII: the Kelvin sign
/// is not a `k`). An entry of `host:port` admits only that port; a bare `host` entry admits only a `Host` with no
/// port at all, so list both spellings if both are in use. A request with no `Host`, or with more than one, is
/// refused. Nothing is normalised: a trailing dot, a space or a userinfo makes a different name.
///
/// Place it outermost, before anything that answers a request (``cors(allowedOrigins:allowedMethods:allowedHeaders:)``
/// included), so a rebinding page never reaches a preflight.
///
/// - Parameter hosts: Entries such as `localhost:8080`, `127.0.0.1:9000`, `[::1]:8080` or `localhost`.
/// - Throws: ``AllowedHostsError`` for an empty list or the first malformed entry. Nothing is dropped or repaired.
public func allowedHosts(_ hosts: [String]) throws(AllowedHostsError) -> Middleware {
    guard !hosts.isEmpty else { throw .noEntries }
    var permitted = Set<[UInt8]>()
    for (index, entry) in hosts.enumerated() {
        let bytes = Array(entry.utf8)
        guard HostSyntax.isHostWithOptionalPort(bytes) else { throw .invalidEntry(at: index) }
        permitted.insert(HostSyntax.lowercased(bytes))
    }
    let allowed = permitted
    return { request, next in
        let given = request.headers[values: .hostField]
        guard given.count == 1, allowed.contains(HostSyntax.lowercased(Array(given[0].utf8))) else {
            // HTTPTypes has no reason phrase for 421, so the title is given: a problem's title is never empty.
            return try Response.problem(
                Problem(status: HTTPResponse.Status(code: 421), code: "misdirected_request", title: "Misdirected Request"))
        }
        return try await next(request)
    }
}

extension HTTPField.Name {
    /// `Host`. HTTPTypes marks its own `host` unavailable (it points at `HTTPRequest.authority`), but this kit keeps the
    /// header: the transport copies an HTTP/2 `:authority` into it, so a handler reads one place for both versions.
    static let hostField: HTTPField.Name = {
        // A constant that is a valid field name; if a change ever makes it invalid, every test fails at once.
        guard let name = HTTPField.Name("Host") else { preconditionFailure("Host is a valid field name") }
        return name
    }()
}

/// The syntax shared by the host allow-list and the CORS origin list.
enum HostSyntax {
    /// ASCII lower case only; every other byte is left as it is.
    static func lowercased(_ bytes: [UInt8]) -> [UInt8] {
        bytes.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }
    }

    /// Whether `bytes` is `host` or `host:port`. Every byte is checked against the small set its position allows (name
    /// characters, hex digits, port digits), so whitespace, controls and anything outside ASCII fail there.
    static func isHostWithOptionalPort(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return false }
        if bytes[0] == UInt8(ascii: "[") {
            guard let close = bytes.firstIndex(of: UInt8(ascii: "]")) else { return false }
            let inner = bytes[(bytes.startIndex + 1)..<close]
            guard !inner.isEmpty, inner.contains(UInt8(ascii: ":")), inner.allSatisfy(isIPv6Byte) else { return false }
            let rest = bytes[(close + 1)...]
            return rest.isEmpty || isPortWithColon(rest)
        }
        let colons = bytes.indices.filter { bytes[$0] == UInt8(ascii: ":") }
        switch colons.count {
        case 0: return isName(bytes[...])
        case 1: return isName(bytes[..<colons[0]]) && isPortWithColon(bytes[colons[0]...])
        default: return false
        }
    }

    private static func isIPv6Byte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x46) || (byte >= 0x61 && byte <= 0x66)
            || byte == UInt8(ascii: ":") || byte == UInt8(ascii: ".")
    }

    /// Letters, digits, `-`, `_` and `.`, in non-empty labels.
    private static func isName(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard !bytes.isEmpty else { return false }
        var labelLength = 0
        for byte in bytes {
            if byte == UInt8(ascii: ".") {
                guard labelLength > 0 else { return false }
                labelLength = 0
                continue
            }
            let valid = (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_")
            guard valid else { return false }
            labelLength += 1
        }
        return labelLength > 0
    }

    /// `:` and then a port: 1 to 65535, in digits with no leading zero.
    private static func isPortWithColon(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard bytes.first == UInt8(ascii: ":") else { return false }
        return port(of: bytes.dropFirst()) != nil
    }

    /// The port in `digits`, or nil when it is not 1 to 65535 written plainly. (No leading zero also rules out 0.)
    static func port(of digits: ArraySlice<UInt8>) -> Int? {
        // At most five digits, so the sum below cannot overflow.
        guard (1...5).contains(digits.count), digits.first != UInt8(ascii: "0"), digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else {
            return nil
        }
        let value = digits.reduce(0) { $0 * 10 + Int($1 - 0x30) }
        return value <= 65535 ? value : nil
    }
}
