// ResponseHeaderPolicy.swift
// SwiftHTTPService
//
// The safe headers every response carries, unless a handler says otherwise.

import HTTPTypes

/// Which headers are added to every response, and when.
///
/// The transport applies the policy to every response it writes, whatever wrote it: a handler, the router, a
/// middleware, a thrown error, a stream, or the transport's own refusal. A header the response already has is never
/// replaced and never repeated, so a handler's own `Cache-Control`, a page's own `Content-Security-Policy` and
/// FleetWatch's own year-long `Strict-Transport-Security` all stand.
///
/// ``secure``, the default, adds:
///
/// | Header | Value | On |
/// |---|---|---|
/// | `X-Content-Type-Options` | `nosniff` | every response |
/// | `Cache-Control` | `no-store` | every response |
/// | `Referrer-Policy` | `no-referrer` | every response |
/// | `X-Frame-Options` | `DENY` | every response, pages included |
/// | `Content-Security-Policy` | `default-src 'none'; frame-ancestors 'none'` | JSON and empty responses only |
/// | `Strict-Transport-Security` | `max-age=604800` | only when the server itself serves TLS |
///
/// The content security policy is not put on a page: the kit cannot know what a page loads, and `default-src 'none'`
/// would blank it. A server that sends HTML sets its own.
///
/// ```swift
/// let files = TLSFiles(certificateChainPath: "/etc/service/chain.pem", privateKeyPath: "/etc/service/key.pem")
///
/// // The default: nothing to write.
/// let configuration = try ServiceConfiguration(port: 8443, tls: files)
///
/// // A slower ramp for HSTS, or none at all.
/// var policy = ResponseHeaderPolicy.secure
/// policy.hsts = .whenServingTLS(maxAge: .seconds(30 * 86_400))
/// let ramped = try ServiceConfiguration(port: 8443, tls: files, responseHeaders: policy)
///
/// // Off, by name, with the reason. The server's owner prints ``optOutReason`` at start.
/// let off = try ResponseHeaderPolicy.disabled(because: "a gateway in front sets these")
/// ```
public struct ResponseHeaderPolicy: Sendable, Equatable {
    /// Added to every response that lacks the field.
    public var always: HTTPFields
    /// Added only to a response whose body is JSON (`application/json` or any `+json` type) or empty.
    public var apiOnly: HTTPFields
    /// When `Strict-Transport-Security` is sent.
    public var hsts: HSTS
    /// Why the policy was turned off, or nil for any other policy.
    public private(set) var optOutReason: String?

    /// When `Strict-Transport-Security` is sent.
    ///
    /// Neither case can say `includeSubDomains` or `preload`: adding them later is additive, and a preload entry is
    /// the one thing here that cannot be taken back within months.
    public enum HSTS: Sendable, Equatable {
        /// Only when the server itself serves TLS, with this `max-age`. A browser ignores the header over plaintext, so
        /// it is not sent there.
        case whenServingTLS(maxAge: Duration)
        /// Never.
        case off
    }

    /// The default policy: see the table above. HSTS is sent for seven days when the server serves TLS.
    public static let secure = ResponseHeaderPolicy(
        always: fields([
            ("X-Content-Type-Options", "nosniff"), ("Cache-Control", "no-store"),
            ("Referrer-Policy", "no-referrer"), ("X-Frame-Options", "DENY"),
        ]),
        apiOnly: fields([("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")]),
        hsts: .whenServingTLS(maxAge: .seconds(604_800)), optOutReason: nil)

    /// A policy that adds nothing, by name, with the reason it was chosen.
    ///
    /// - Parameter reason: Why. Not blank: an opt-out is a decision someone can ask about.
    /// - Throws: ``ConfigurationError`` for `responseHeaders.reason` if the reason is blank.
    public static func disabled(because reason: String) throws(ConfigurationError) -> ResponseHeaderPolicy {
        guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationError(field: "responseHeaders.reason", reason: .empty)
        }
        return ResponseHeaderPolicy(always: HTTPFields(), apiOnly: HTTPFields(), hsts: .off, optOutReason: reason)
    }

    /// `response` with this policy's headers added, wherever it has none of its own.
    ///
    /// Pure: no transport is involved, so a server that does not use this package's transport can call it too.
    ///
    /// - Parameters:
    ///   - response: What a handler, or the transport, made.
    ///   - overTLS: Whether the server itself serves TLS. HSTS is only ever sent when it does.
    public func applying(to response: Response, overTLS: Bool) -> Response {
        var out = response
        for field in always { Self.add(field, to: &out.headers) }
        if Self.isAPI(response) {
            for field in apiOnly { Self.add(field, to: &out.headers) }
        }
        if overTLS, case .whenServingTLS(let maxAge) = hsts {
            let seconds = max(0, maxAge.components.seconds)
            Self.add(HTTPField(name: .strictTransportSecurity, value: "max-age=\(seconds)"), to: &out.headers)
        }
        return out
    }

    // MARK: Helpers

    private static func add(_ field: HTTPField, to headers: inout HTTPFields) {
        guard headers[field.name] == nil else { return }
        headers.append(field)
    }

    /// JSON, or nothing at all: the responses a browser is never meant to render.
    private static func isAPI(_ response: Response) -> Bool {
        if let type = response.headers[.contentType] {
            let media = type.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            if media == "application/json" || media.hasSuffix("+json") { return true }
        }
        // A stream has no body yet; what it is shows in its type, so it only counts if that says JSON.
        return response.body.isEmpty && response.stream == nil
    }

    private static func fields(_ pairs: [(String, String)]) -> HTTPFields {
        var fields = HTTPFields()
        for (name, value) in pairs {
            // Constants that are valid field names; a name that were not would show as a missing header in every test.
            if let name = HTTPField.Name(name) { fields.append(HTTPField(name: name, value: value)) }
        }
        return fields
    }
}
