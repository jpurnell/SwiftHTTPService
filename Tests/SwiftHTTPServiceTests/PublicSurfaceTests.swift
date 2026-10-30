import Foundation
import HTTPTypes
import SwiftHTTPService
import Testing

/// The 0.6.0 audit of the public surface (DesignProposal_0.6.0, section 3), pinned from outside the module: no
/// `@testable`, so these can only use what a consumer can.
@Suite("Public surface")
struct PublicSurfaceTests {

    @Test("Value types a consumer keys a dictionary or fills a set with are Hashable, and equal values hash alike")
    func hashableValues() throws {
        let tagA = try #require(EntityTag(opaque: "abc", isWeak: false))
        let tagB = try #require(EntityTag(opaque: "abc", isWeak: false))
        let weak = try #require(EntityTag(opaque: "abc", isWeak: true))
        #expect(Set([tagA, tagB, weak]).count == 2)

        #expect(Set([QueryItem(name: "a", value: "1"), QueryItem(name: "a", value: "1"), QueryItem(name: "a", value: nil)]).count == 2)
        #expect(Set([HTTPProtocolVersion.http1_0, .http1_1, .http2, .http2]).count == 3)
        #expect(Set([Cookie.SameSite.strict, .lax, .none, .lax]).count == 3)

        let kinds: [ServiceConfiguration.Forwarding] = [.none, .xForwardedFor, .proxyProtocol, .none]
        #expect(Set(kinds).count == 3)
        let reuse: [ServiceConfiguration.ConnectionReuse] = [.keepAlive, .closeAfterResponse, .keepAlive]
        #expect(Set(reuse).count == 2)
        let protocols: [ServiceConfiguration.Protocols] = [.http1, .http1AndHTTP2, .http1]
        #expect(Set(protocols).count == 2)

        let streamErrors: [StreamError] = [.closed, .byteLimit, .writeTimeout, .durationLimit, .closed]
        #expect(Set(streamErrors).count == 4)

        let limit = try RateLimit(requests: 5, per: .seconds(1))
        #expect(Set([limit, try RateLimit(requests: 5, per: .seconds(1)), try RateLimit(requests: 6, per: .seconds(1))]).count == 2)
    }

    @Test("A request is built with a typed error, like every other throwing initialiser in the kit")
    func typedRequestError() {
        do throws(RequestError) {
            _ = try Request(method: .get, target: "no-slash", headers: HTTPFields(), body: Data())
            Issue.record("accepted a target that is not origin-form")
        } catch {
            #expect(error == .malformedTarget)
        }
    }

    @Test("The connection mode is reachable under its new name without a deprecation")
    func newNameIsAvailable() throws {
        let configuration = try ServiceConfiguration(connectionReuse: .closeAfterResponse)
        #expect(configuration.connectionReuse == .closeAfterResponse)
    }
}
