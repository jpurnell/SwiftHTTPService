import Foundation
import HTTPTypes
import Testing
@testable import SwiftHTTPService

@Suite("Request version")
struct RequestVersionTests {

    @Test("A request built without a version is HTTP/1.1, so code written before the version existed compiles and behaves as it did")
    func defaultVersion() throws {
        let request = try Request(method: .get, target: "/x", headers: HTTPFields(), body: Data())
        #expect(request.httpVersion == .http1_1)
    }

    @Test("The version given is the version kept", arguments: [HTTPProtocolVersion.http1_0, .http1_1, .http2])
    func givenVersion(_ version: HTTPProtocolVersion) throws {
        let request = try Request(method: .get, target: "/x", headers: HTTPFields(), body: Data(), httpVersion: version)
        #expect(request.httpVersion == version)
    }

    @Test("The versions are distinct, and print as the protocol is written")
    func descriptions() {
        #expect(HTTPProtocolVersion.http1_0.description == "HTTP/1.0")
        #expect(HTTPProtocolVersion.http1_1.description == "HTTP/1.1")
        #expect(HTTPProtocolVersion.http2.description == "HTTP/2")
    }
}
