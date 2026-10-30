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
///
/// The set grows: ``busy`` and ``versionNotSupported`` joined in 0.6.0. A `switch` over it should end in a
/// `default`, so that a kind added in a minor release is not a compile error in a server that has not met it yet.
public enum TransportRefusal: Sendable, Hashable, CaseIterable, CustomStringConvertible {
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
    /// A connection beyond `Limits.maximumConnections`, answered `503` with `Retry-After` and closed. It is refused
    /// before its request is read, so a record of it has a peer and no request line. Over TLS the connection is
    /// closed before the handshake instead, and no hook is called (see ``Limits/maximumConnections``).
    case busy
    /// A request line naming an HTTP major version other than 1 (`HTTP/2.0`, `HTTP/3.0`), answered `505`. HTTP/2 is
    /// spoken over TLS with ALPN, never as a request line in HTTP/1.1 framing.
    case versionNotSupported

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
        case .serviceUnavailable: self = .busy
        case .versionNotSupported: self = .versionNotSupported
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
        case .busy: .serviceUnavailable
        case .versionNotSupported: .versionNotSupported
        }
    }
}

/// What the transport knows about a refusal: who asked and, when the request line had been read, what for.
///
/// The request line comes from a stranger and is going to be written to a log, so it is made safe first: the method
/// is shown only if it is a token of at most 32 characters, and the target has every byte outside visible ASCII
/// written as `%XX` (so it cannot end a line or carry a control sequence) and is cut at 512 characters, marked
/// `...`. Nothing here is ever sent back to the peer.
public struct RefusalRecord: Sendable, Hashable {
    /// What was refused.
    public let kind: TransportRefusal
    /// The socket's peer, if the transport knows it.
    public let peerAddress: String?
    /// The client, as a trusted proxy reported it (see ``ServiceConfiguration/Forwarding``): the peer if none did.
    public let remoteAddress: String?
    /// The request method, if the request line had been read.
    public let method: String?
    /// The request target, escaped and cut short, if the request line had been read.
    public let target: String?
    /// The version of HTTP, if it is known.
    public let httpVersion: HTTPProtocolVersion?

    /// Creates a record. The transport makes these; a server's tests make them to exercise the function it gives
    /// to ``RefusalHooks/record`` without a socket. Nothing is checked or made safe here: the escaping described
    /// above is the transport's, applied before it builds one.
    public init(
        kind: TransportRefusal, peerAddress: String?, remoteAddress: String?, method: String?, target: String?,
        httpVersion: HTTPProtocolVersion?
    ) {
        self.kind = kind
        self.peerAddress = peerAddress
        self.remoteAddress = remoteAddress
        self.method = method
        self.target = target
        self.httpVersion = httpVersion
    }

    /// The longest target shown, in characters, before the `...` that marks a cut.
    static let maximumTargetCharacters = 512

    /// The text of a request target: visible ASCII (0x21 to 0x7E) as written, every other byte as `%XX`.
    static func text(ofTarget bytes: [UInt8]) -> String {
        var out = String.UnicodeScalarView()
        var count = 0
        let digits = Array("0123456789ABCDEF".unicodeScalars)
        for byte in bytes {
            if byte >= 0x21 && byte <= 0x7E {
                out.append(Unicode.Scalar(byte))
                count += 1
            } else {
                out.append("%")
                out.append(digits[Int(byte >> 4)])
                out.append(digits[Int(byte & 0x0F)])
                count += 3
            }
            if count > maximumTargetCharacters { break }
        }
        let text = String(out)
        guard text.unicodeScalars.count > maximumTargetCharacters else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.prefix(maximumTargetCharacters))) + "..."
    }

    /// The text of a method: an RFC 9110 token of 1 to 32 characters, or nil.
    static func text(ofMethod bytes: [UInt8]) -> String? {
        let allowed = Set("!#$%&'*+-.^_`|~".utf8)
        guard (1...32).contains(bytes.count), bytes.allSatisfy({
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || allowed.contains($0)
        }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// What a server does about the transport's own refusals.
///
/// The closures run on the connection's event loop, so they must be quick and must not block. None can throw.
/// The status of a refusal, the closing of the connection and the headers the transport owns (`Content-Length`,
/// `Date`, `Connection`) stay the transport's: a hook that could change them could turn the refusal of a
/// smuggling attempt into a `200`.
public struct RefusalHooks: Sendable {
    /// Gives a refusal its body and headers. Return nil to keep the fixed default. Any status in the response is
    /// ignored; the refusal's own is used.
    public let respond: (@Sendable (TransportRefusal) -> Response?)?
    /// Called once for each refusal, before it is written, for counting.
    public let observe: (@Sendable (TransportRefusal) -> Void)?
    /// Called once for each refusal, before it is written, with who asked and what for: the place to write the log
    /// line for a request the transport refused before any handler or middleware saw it.
    public let record: (@Sendable (RefusalRecord) -> Void)?

    /// Creates hooks; with none, the transport's fixed refusals are unchanged.
    public init(
        respond: (@Sendable (TransportRefusal) -> Response?)? = nil, observe: (@Sendable (TransportRefusal) -> Void)? = nil,
        record: (@Sendable (RefusalRecord) -> Void)? = nil
    ) {
        self.respond = respond
        self.observe = observe
        self.record = record
    }
}
