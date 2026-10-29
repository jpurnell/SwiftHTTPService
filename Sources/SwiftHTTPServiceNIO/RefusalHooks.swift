// RefusalHooks.swift
// SwiftHTTPServiceNIO
//
// Letting a server give the transport's own refusals its own body, and count them.

import HTTPTypes
import SwiftHTTPService

/// A refusal the transport makes without asking the handler.
///
/// None of these carries anything the peer sent: a refusal that repeated a target or a header would be a way to
/// read the server's insides, or to put text of the peer's choosing in a response.
public enum TransportRefusal: Sendable, Equatable, CaseIterable, CustomStringConvertible {
    /// A request that could be read two ways, or is not valid HTTP (a repeated `Host`, a bad `Content-Length`).
    case badRequest
    /// A target that is not strict origin-form.
    case malformedTarget
    /// A head or a body that did not arrive in time.
    case requestTimeout
    /// A body past the bound.
    case bodyTooLarge
    /// An `Expect` the server cannot meet.
    case expectationFailed
    /// A head with too many bytes or too many fields.
    case headersTooLarge
    /// The handler threw, or returned a status that is not a final one.
    case internalError

    /// The status the transport answers with. A hook cannot change it.
    public var statusCode: Int { refusal.statusCode }

    /// The stable, machine-readable code of the default body.
    public var code: String { refusal.code }

    /// The code.
    public var description: String { code }

    init(_ refusal: Refusal) {
        switch refusal {
        case .badRequest: self = .badRequest
        case .malformedTarget: self = .malformedTarget
        case .requestTimeout: self = .requestTimeout
        case .bodyTooLarge: self = .bodyTooLarge
        case .expectationFailed: self = .expectationFailed
        case .headersTooLarge: self = .headersTooLarge
        case .internalError: self = .internalError
        }
    }

    var refusal: Refusal {
        switch self {
        case .badRequest: .badRequest
        case .malformedTarget: .malformedTarget
        case .requestTimeout: .requestTimeout
        case .bodyTooLarge: .bodyTooLarge
        case .expectationFailed: .expectationFailed
        case .headersTooLarge: .headersTooLarge
        case .internalError: .internalError
        }
    }
}

/// What a server does about the transport's own refusals.
///
/// Both closures run on the connection's event loop, so they must be quick and must not block. Neither can throw.
/// The status of a refusal, the closing of the connection and the headers the transport owns (`Content-Length`,
/// `Date`, `Connection`) stay the transport's: a hook that could change them could turn the refusal of a
/// smuggling attempt into a `200`.
public struct RefusalHooks: Sendable {
    /// Gives a refusal its body and headers. Return nil to keep the fixed default. Any status in the response is
    /// ignored; the refusal's own is used.
    public let respond: (@Sendable (TransportRefusal) -> Response?)?
    /// Called once for each refusal, before it is written, for counting and logging.
    public let observe: (@Sendable (TransportRefusal) -> Void)?

    /// Creates hooks; with neither, the transport's fixed refusals are unchanged.
    public init(
        respond: (@Sendable (TransportRefusal) -> Response?)? = nil, observe: (@Sendable (TransportRefusal) -> Void)? = nil
    ) {
        self.respond = respond
        self.observe = observe
    }
}
