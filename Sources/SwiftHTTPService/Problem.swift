// Problem.swift
// SwiftHTTPService
//
// RFC 9457 problem details.

import HTTPTypes

/// An RFC 9457 problem: what went wrong, with a stable machine-readable `code`.
///
/// Clients branch on `code` and never on the text. Two problems built from the same inputs encode to the
/// same bytes, so a server can make two different refusals indistinguishable (an unknown id and an id the
/// caller may not see).
public struct Problem: Sendable, Equatable, Encodable {
    /// A URI reference naming the problem type. `about:blank` when the status says it all.
    public let type: String
    /// A short summary. Defaults to the status's reason phrase.
    public let title: String
    /// The HTTP status as a number.
    public let status: Int
    /// The stable, machine-readable code.
    public let code: String
    /// Explanation specific to this occurrence, if any. Never contains a value from the request.
    public let detail: String?

    /// The status as the type HTTP uses.
    var httpStatus: HTTPResponse.Status { HTTPResponse.Status(code: status) }

    /// Creates a problem.
    public init(
        status: HTTPResponse.Status, code: String, title: String? = nil, detail: String? = nil, type: String = "about:blank"
    ) {
        self.type = type
        self.title = title ?? status.reasonPhrase
        self.status = status.code
        self.code = code
        self.detail = detail
    }
}
