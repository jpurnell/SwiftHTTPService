import Foundation
import NIOConcurrencyHelpers
import NIOPosix
import SwiftHTTPService
import Testing
@testable import SwiftHTTPServiceNIO

/// The three layers together, in the order the design gives (access log, request id, rate limiter), on a real
/// connection: what a client sees and what the log records.
@Suite("Middleware over the wire", .serialized)
struct MiddlewareOverTheWireTests {

    @Test("Every response carries an id, a request over the limit is a 429 with Retry-After, and the log has one clean line for each")
    func together() async throws {
        let entries = NIOLockedValueBox<[AccessLogEntry]>([])
        let limiter = try RateLimiter(try RateLimit(requests: 1, per: .seconds(60), burst: 2))
        let handler = wrap(ok("hello"), with: [
            accessLog(sink: { entry in entries.withLockedValue { $0.append(entry) } }),
            requestID(),
            rateLimit(limiter),
        ])
        let running = try await startServer(handler: handler)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        // The client offers an id that is not safe to log; the server must not echo it.
        let hostile = "evil\"id"
        var statuses: [Int] = []
        var ids: [String?] = []
        var retryAfter: String?
        for _ in 0..<3 {                                       // one connection each, all from the same peer address
            let client = try await RawClient.connect(to: running.address, group: group)
            try await client.send("GET /v1/things?token=secret HTTP/1.1\r\nHost: h\r\nX-Request-ID: \(hostile)\r\nConnection: close\r\n\r\n")
            let response = try #require(try await client.response())
            statuses.append(response.status)
            ids.append(response.header("X-Request-ID"))
            retryAfter = response.header("Retry-After") ?? retryAfter
            await client.close()
        }
        try await group.shutdownGracefully()
        await running.server.shutdown()

        #expect(statuses == [200, 200, 429])                    // a burst of two, then refused
        #expect(ids.compactMap { $0 }.count == 3)
        #expect(!ids.compactMap { $0 }.contains(hostile))
        #expect(Set(ids.compactMap { $0 }).count == 3)         // three different generated ids
        // One a minute with a burst of two: the third waits until T*(3-2) = 60 s after the first, less the few
        // milliseconds already spent, rounded up.
        #expect(retryAfter == "60")
        let logged = entries.withLockedValue { $0 }
        #expect(logged.map(\.status) == [200, 200, 429])
        #expect(logged.allSatisfy { $0.path == "/v1/things" })
        #expect(logged.allSatisfy { !$0.line.contains("secret") })
        #expect(logged.compactMap(\.requestID).count == 3)
    }
}
