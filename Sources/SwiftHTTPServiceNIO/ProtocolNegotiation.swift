// ProtocolNegotiation.swift
// SwiftHTTPServiceNIO
//
// What the server offers in ALPN, and what it makes of the answer.

import SwiftHTTPService

/// ALPN, kept apart from the sockets so the rules can be tested without a handshake.
enum ProtocolNegotiation {

    /// The version a connection will speak.
    enum Version: Equatable, Sendable {
        case http1
        case http2
    }

    /// The protocols offered in the TLS handshake, most preferred first.
    static func offer(for protocols: ServiceConfiguration.Protocols) -> [String] {
        switch protocols {
        case .http1: ["http/1.1"]
        case .http1AndHTTP2: ["h2", "http/1.1"]
        }
    }

    /// The version for a handshake's result, or nil if the connection should be closed.
    ///
    /// No result means the peer named no protocol; a server that speaks HTTP/1.1 answers it as HTTP/1.1.
    /// Anything that was not offered is refused, whatever the peer sent: the match is exact and
    /// case-sensitive, as ALPN identifiers are.
    static func select(negotiated: String?, configured protocols: ServiceConfiguration.Protocols) -> Version? {
        guard let negotiated else { return .http1 }
        guard offer(for: protocols).contains(negotiated) else { return nil }
        return negotiated == "h2" ? .http2 : .http1
    }
}
