import Testing
import SwiftHTTPService
@testable import SwiftHTTPServiceNIO

/// What the server offers in ALPN, and what it makes of the answer. The offer is most preferred first,
/// and a protocol that is not offered is never selected: a peer cannot talk the server into HTTP/2 when
/// the configuration said HTTP/1.1.
@Suite("Protocol negotiation")
struct ProtocolNegotiationTests {

    @Test("HTTP/1.1 only offers http/1.1 and nothing else")
    func offerHTTP1() {
        #expect(ProtocolNegotiation.offer(for: .http1) == ["http/1.1"])
    }

    @Test("Both offers h2 first, then http/1.1")
    func offerBoth() {
        #expect(ProtocolNegotiation.offer(for: .http1AndHTTP2) == ["h2", "http/1.1"])
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let protocols: ServiceConfiguration.Protocols
        let negotiated: String?
        let expected: ProtocolNegotiation.Version?
        var testDescription: String { "\(protocols) negotiated \(negotiated ?? "nothing")" }
    }

    // Worked out from RFC 7301 and RFC 9113 §3.2: no ALPN result means the peer named no protocol, and a
    // server that speaks HTTP/1.1 treats that as HTTP/1.1; h2 is only HTTP/2 if it was offered.
    static let selections: [Case] = [
        Case(protocols: .http1AndHTTP2, negotiated: "h2", expected: .http2),
        Case(protocols: .http1AndHTTP2, negotiated: "http/1.1", expected: .http1),
        Case(protocols: .http1AndHTTP2, negotiated: nil, expected: .http1),
        Case(protocols: .http1, negotiated: "http/1.1", expected: .http1),
        Case(protocols: .http1, negotiated: nil, expected: .http1),
        Case(protocols: .http1, negotiated: "h2", expected: nil),          // never offered, so refused
        Case(protocols: .http1AndHTTP2, negotiated: "h3", expected: nil),  // unknown, so refused
        Case(protocols: .http1AndHTTP2, negotiated: "", expected: nil),
        Case(protocols: .http1AndHTTP2, negotiated: "H2", expected: nil),  // ALPN ids are case-sensitive
    ]

    @Test("The negotiated protocol picks the version, and anything not offered picks none", arguments: selections)
    func selection(_ c: Case) {
        #expect(ProtocolNegotiation.select(negotiated: c.negotiated, configured: c.protocols) == c.expected)
    }
}
