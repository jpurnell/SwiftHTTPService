import Foundation
import SwiftHTTPService
import Testing
@testable import SwiftHTTPServiceNIO

/// The kit's half of `Scripts/proxy-protocol-check.sh`: serves, on a fixed loopback port, behind the PROXY protocol, and
/// answers `GET /who` with the client address the handler saw and the socket's peer.
///
/// It is not a test of anything by itself and is skipped unless the script sets `PROXY_CHECK_BACKEND_PORT`. The script puts
/// HAProxy in front, sends requests, and compares what comes back with the source address it told HAProxy to claim.
@Suite("PROXY protocol behind a balancer (driven by Scripts/proxy-protocol-check.sh)", .serialized)
struct BalancerCheckServer {

    static let environment = ProcessInfo.processInfo.environment
    static let port: UInt16? = environment["PROXY_CHECK_BACKEND_PORT"].flatMap { UInt16($0) }

    @Test("Serve behind the PROXY protocol until the script says stop",
          .enabled(if: BalancerCheckServer.port != nil, "set by Scripts/proxy-protocol-check.sh"))
    func serve() async throws {
        let port = try #require(Self.port)
        let ready = try #require(Self.environment["PROXY_CHECK_READY"], "PROXY_CHECK_READY names the file written when the server is up")
        let stop = try #require(Self.environment["PROXY_CHECK_STOP"], "PROXY_CHECK_STOP names the file whose appearance ends the run")
        let seconds = Self.environment["PROXY_CHECK_SECONDS"].flatMap { Int($0) } ?? 300

        // The balancer is on loopback, so loopback is the one trusted proxy: it must send the header, and anyone else who
        // reaches this port from loopback without one is refused.
        let server = HTTPServer(
            configuration: try ServiceConfiguration(
                port: port, trustedProxies: ["127.0.0.0/8"], forwarding: .proxyProtocol),
            handler: { request in
                Response(status: .ok, body: Data("remote=\(request.remoteAddress ?? "-");peer=\(request.peerAddress ?? "-")".utf8))
            })
        _ = try await server.start()
        try Data("up\n".utf8).write(to: URL(fileURLWithPath: ready))
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !FileManager.default.fileExists(atPath: stop), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        await server.shutdown()
    }
}
