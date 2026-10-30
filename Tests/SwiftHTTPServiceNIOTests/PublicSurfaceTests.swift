import Foundation
import SwiftHTTPService
import SwiftHTTPServiceNIO
import Testing

/// The transport's half of the 0.6.0 audit, from outside the module: no `@testable`.
@Suite("Public surface (transport)")
struct TransportPublicSurfaceTests {

    @Test("A refusal kind can be a dictionary key, which is what counting refusals by kind needs")
    func refusalKindIsHashable() {
        var counts: [TransportRefusal: Int] = [:]
        for kind in [TransportRefusal.busy, .badRequest, .busy, .versionNotSupported] { counts[kind, default: 0] += 1 }
        #expect(counts[.busy] == 2)
        #expect(counts[.badRequest] == 1)
        #expect(counts[.versionNotSupported] == 1)
        #expect(counts[.internalError] == nil)
    }

    @Test("A refusal record can be built by a consumer, so the function it hands to `record` can be tested without a socket")
    func recordIsConstructible() {
        let record = RefusalRecord(
            kind: .busy, peerAddress: "192.0.2.1", remoteAddress: "198.51.100.7", method: nil, target: nil, httpVersion: nil)
        #expect(record.kind == .busy)
        #expect(record.peerAddress == "192.0.2.1")
        #expect(record.remoteAddress == "198.51.100.7")
        #expect(record.method == nil && record.target == nil && record.httpVersion == nil)
        #expect(record == RefusalRecord(kind: .busy, peerAddress: "192.0.2.1", remoteAddress: "198.51.100.7", method: nil, target: nil, httpVersion: nil))
        #expect(Set([record, record]).count == 1)
    }

    @Test("A bound address is Hashable")
    func boundAddress() {
        #expect(Set([BoundAddress(host: "127.0.0.1", port: 80), BoundAddress(host: "127.0.0.1", port: 80), BoundAddress(host: "::1", port: 80)]).count == 2)
    }
}
