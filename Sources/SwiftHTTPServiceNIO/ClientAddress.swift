// ClientAddress.swift
// SwiftHTTPServiceNIO
//
// Who the client is, when a proxy stands between it and the server.

import HTTPTypes
import SwiftHTTPService

private enum ForwardingHeader {
    /// `X-Forwarded-For`, the de facto header in which each proxy appends the address it received a request from.
    static let xForwardedFor: HTTPField.Name = {
        // A constant that is a valid field name; if a change ever makes it invalid, every test fails at once.
        guard let name = HTTPField.Name("X-Forwarded-For") else { preconditionFailure("a valid field name") }
        return name
    }()
}

extension HTTPFields {
    /// Every `X-Forwarded-For` field, in the order sent.
    var forwardedForValues: [String] { self[values: ForwardingHeader.xForwardedFor] }
}

/// The address a request is attributed to.
///
/// One rule decides it: **forwarded information is believed only from a trusted peer.** A client can write any
/// header it likes, so a header from anyone else is ignored. From a trusted proxy, `X-Forwarded-For` is read from
/// the right, because each proxy appends the address it received the request from: what a client wrote is at the
/// left and a trusted proxy's addition is at the right. The client is the first address, walking from the right,
/// that is not itself a trusted proxy.
enum ClientAddress {
    /// The most `X-Forwarded-For` entries believed, counted from the right. A longer list is not a chain of proxies
    /// anyone runs, and what is left of the rightmost entries is what a client wrote: it is dropped, not believed, and
    /// not allowed to move the answer (a client that could push the list past a limit would be attributed to the proxy,
    /// and share its rate-limit key and its bans).
    static let maximumForwardedEntries = 20

    /// The address to attribute a request to.
    ///
    /// - Parameters:
    ///   - peer: The socket's peer.
    ///   - proxied: The client a PROXY protocol header named, if one was read from a trusted peer.
    ///   - forwardedFor: The request's `X-Forwarded-For` fields.
    ///   - configuration: Where the trust is configured.
    /// - Returns: The client, or the peer if nothing forwarded can be believed; nil only if the peer is unknown.
    static func resolve(peer: String?, proxied: String?, forwardedFor: [String], configuration: ServiceConfiguration) -> String? {
        guard let peer else { return nil }
        let blocks = configuration.trustedProxies
        func isTrusted(_ address: String) -> Bool { blocks.contains { $0.contains(address) } }

        switch configuration.forwarding {
        case .none:
            return peer
        case .proxyProtocol:
            guard let proxied, isTrusted(peer) else { return peer }
            return proxied
        case .xForwardedFor:
            guard isTrusted(peer), !forwardedFor.isEmpty else { return peer }
            let entries = forwardedFor.joined(separator: ",")
                .split(separator: ",", omittingEmptySubsequences: false)
                .suffix(maximumForwardedEntries)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            for entry in entries.reversed() {
                // Something not an address: believe none of it. One spelling per address, so a limit keys on one string.
                guard let address = NetworkBlock.canonicalAddress(entry) else { return peer }
                if !isTrusted(address) { return address }
            }
            return entries.first.flatMap(NetworkBlock.canonicalAddress) ?? peer   // every hop is a trusted proxy: the first is the client
        }
    }
}
