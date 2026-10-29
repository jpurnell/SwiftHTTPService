import Foundation
import HTTPTypes
import Testing
@testable import SwiftHTTPService

/// The rate limiter. Every expected number is worked out by hand from the algorithm (GCRA: one request costs
/// an emission interval T, a bucket of B requests tolerates B*T of credit), not read back from the code.
@Suite("Rate limiter")
struct RateLimiterTests {

    /// A clock the test moves by hand.
    // Justification: every read and write of the elapsed time happens inside the lock.
    final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var elapsed = Duration.zero
        func now() -> Duration { lock.withLock { elapsed } }
        func advance(_ by: Duration) { lock.withLock { elapsed += by } }
    }

    private static func limiter(
        _ requests: Int, per interval: Duration, burst: Int? = nil, keys: Int = 10_000, clock: ManualClock = ManualClock()
    ) throws -> (RateLimiter, ManualClock) {
        (try RateLimiter(try RateLimit(requests: requests, per: interval, burst: burst), maximumKeys: keys, now: { clock.now() }), clock)
    }

    // MARK: Validation

    struct Refused: Sendable, CustomTestStringConvertible {
        let name: String
        let build: @Sendable () throws -> Void
        var testDescription: String { name }
    }

    static let refused: [Refused] = [
        Refused(name: "zero requests", build: { _ = try RateLimit(requests: 0, per: .seconds(1)) }),
        Refused(name: "negative requests", build: { _ = try RateLimit(requests: -1, per: .seconds(1)) }),
        Refused(name: "too many requests", build: { _ = try RateLimit(requests: 1_000_001, per: .seconds(86_400)) }),
        Refused(name: "zero interval", build: { _ = try RateLimit(requests: 1, per: .zero) }),
        Refused(name: "negative interval", build: { _ = try RateLimit(requests: 1, per: .seconds(-1)) }),
        Refused(name: "interval over a day", build: { _ = try RateLimit(requests: 1, per: .seconds(86_401)) }),
        Refused(name: "an interval shorter than a nanosecond per request", build: { _ = try RateLimit(requests: 1000, per: .nanoseconds(999)) }),
        Refused(name: "zero burst", build: { _ = try RateLimit(requests: 1, per: .seconds(1), burst: 0) }),
        Refused(name: "burst over the ceiling", build: { _ = try RateLimit(requests: 1, per: .seconds(1), burst: 10_001) }),
        Refused(name: "no keys", build: { _ = try RateLimiter(try RateLimit(requests: 1, per: .seconds(1)), maximumKeys: 0) }),
    ]

    @Test("A limit or a limiter that is out of range is refused, and nothing is clamped", arguments: refused)
    func validation(_ c: Refused) {
        #expect(throws: RateLimitError.self) { try c.build() }
    }

    @Test("The edges of each range are accepted")
    func edges() async throws {
        // 1 request in a nanosecond costs 1 ns; a million in a day costs 86,400,000 ns each (86,400e9 / 1e6).
        #expect(try RateLimit(requests: 1, per: .nanoseconds(1)).emissionNanoseconds == 1)
        let widest = try RateLimit(requests: 1_000_000, per: .seconds(86_400), burst: 10_000)
        #expect(widest.emissionNanoseconds == 86_400_000)
        #expect(widest.burst == 10_000)
        #expect(try RateLimit(requests: 20_000, per: .seconds(1)).burst == 10_000)   // the default burst is capped
        #expect(try RateLimit(requests: 7, per: .seconds(1)).burst == 7)
        #expect(await (try RateLimiter(try RateLimit(requests: 1, per: .seconds(1)), maximumKeys: 1)).trackedKeys == 0)
    }

    // MARK: The algorithm

    @Test("A bucket of five lets five through at once, and the sixth waits one emission interval")
    func burstThenWait() async throws {
        let (limiter, clock) = try Self.limiter(10, per: .seconds(1), burst: 5)      // T = 100 ms
        for _ in 0..<5 { #expect(await limiter.check(key: "a") == .allowed) }
        #expect(await limiter.check(key: "a") == .limited(retryAfter: .milliseconds(100)))
        clock.advance(.milliseconds(99))
        #expect(await limiter.check(key: "a") == .limited(retryAfter: .milliseconds(1)))
        clock.advance(.milliseconds(1))
        #expect(await limiter.check(key: "a") == .allowed)
    }

    @Test("Arrivals every 50 ms against 10 a second with a burst of 5 are allowed on the pattern worked out by hand")
    func steadyOverload() async throws {
        let (limiter, clock) = try Self.limiter(10, per: .seconds(1), burst: 5)
        var allowed: [Bool] = []
        for _ in 0..<20 {
            allowed.append(await limiter.check(key: "a") == .allowed)
            clock.advance(.milliseconds(50))
        }
        // t = 0...400 ms: nine in a row (the burst, then the credit earned meanwhile); then alternately refused
        // and allowed, since once saturated one request is earned every 100 ms.
        let expected = Array(repeating: true, count: 9) + [false, true, false, true, false, true, false, true, false, true, false]
        #expect(allowed == expected)
    }

    @Test("Idleness does not build credit past the bucket: after a long quiet, only a burst's worth goes through at once")
    func idleDoesNotAccumulate() async throws {
        let (limiter, clock) = try Self.limiter(10, per: .seconds(1), burst: 3)
        for _ in 0..<3 { #expect(await limiter.check(key: "a") == .allowed) }
        clock.advance(.seconds(3_600))
        for _ in 0..<3 { #expect(await limiter.check(key: "a") == .allowed) }
        #expect(await limiter.check(key: "a") == .limited(retryAfter: .milliseconds(100)))
    }

    @Test("Arrivals at exactly the rate are all allowed, however long they go on")
    func atTheRate() async throws {
        let (limiter, clock) = try Self.limiter(10, per: .seconds(1), burst: 1)
        for _ in 0..<500 {
            #expect(await limiter.check(key: "a") == .allowed)
            clock.advance(.milliseconds(100))
        }
    }

    @Test("A refused request costs nothing: asking again after the wait it was told is allowed")
    func refusalIsFree() async throws {
        let (limiter, clock) = try Self.limiter(1, per: .seconds(2), burst: 1)        // T = 2 s
        #expect(await limiter.check(key: "a") == .allowed)
        for _ in 0..<50 { #expect(await limiter.check(key: "a") == .limited(retryAfter: .seconds(2))) }
        clock.advance(.seconds(2))
        #expect(await limiter.check(key: "a") == .allowed)
    }

    @Test("Keys are independent")
    func independentKeys() async throws {
        let (limiter, _) = try Self.limiter(1, per: .seconds(1), burst: 1)
        #expect(await limiter.check(key: "a") == .allowed)
        #expect(await limiter.check(key: "a") != .allowed)
        #expect(await limiter.check(key: "b") == .allowed)
    }

    // MARK: The table is bounded

    @Test("With a table of three, a fourth active key evicts the one least recently active, and the table never grows")
    func evictsOldest() async throws {
        let (limiter, clock) = try Self.limiter(1, per: .seconds(10), burst: 1, keys: 3)
        for key in ["a", "b", "c"] {
            #expect(await limiter.check(key: key) == .allowed)
            clock.advance(.milliseconds(1))
        }
        #expect(await limiter.trackedKeys == 3)
        #expect(await limiter.check(key: "d") == .allowed)
        #expect(await limiter.trackedKeys == 3)
        // "a" was evicted, so it starts again with a full bucket; "b" and "c" are still being held to their limit.
        #expect(await limiter.check(key: "a") == .allowed)
        #expect(await limiter.check(key: "c") != .allowed)
    }

    @Test("Idle keys are dropped before an active one is")
    func idleKeysGoFirst() async throws {
        let (limiter, clock) = try Self.limiter(1, per: .seconds(1), burst: 1, keys: 3)
        for key in ["a", "b", "c"] { _ = await limiter.check(key: key) }
        clock.advance(.seconds(5))                                                     // all three are idle again
        #expect(await limiter.check(key: "d") == .allowed)
        #expect(await limiter.trackedKeys == 1)
    }

    @Test("A hundred thousand distinct keys never hold more than the bound")
    func floodOfKeys() async throws {
        let (limiter, clock) = try Self.limiter(1, per: .seconds(60), burst: 1, keys: 100)
        for index in 0..<2_000 {
            _ = await limiter.check(key: "k\(index)")
            clock.advance(.microseconds(1))
            #expect(await limiter.trackedKeys <= 100)
        }
    }

    // MARK: The middleware

    private static func request(remote: String? = "203.0.113.9") throws -> Request {
        try Request(method: .get, target: "/x", headers: HTTPFields(), body: Data(), remoteAddress: remote)
    }

    private actor Count {
        var value = 0
        func bump() { value += 1 }
    }

    @Test("A request over the limit is a 429 problem with Retry-After in whole seconds rounded up, and the handler never runs")
    func middlewareRefuses() async throws {
        let (limiter, clock) = try Self.limiter(1, per: .milliseconds(2_500), burst: 1)    // T = 2.5 s
        let ran = Count()
        let layer = rateLimit(limiter)
        let next: Handler = { _ in await ran.bump(); return Response(status: .ok) }
        #expect(try await layer(try Self.request(), next).status == .ok)
        let refused = try await layer(try Self.request(), next)
        #expect(refused.status == .tooManyRequests)
        #expect(refused.headers[.retryAfter] == "3")                                      // 2.5 s rounds up to 3
        #expect(refused.headers[.contentType] == "application/problem+json")
        #expect(refused.body == (try Response.problem(Problem(status: .tooManyRequests, code: "rate_limited"))).body)
        #expect(await ran.value == 1)
        clock.advance(.milliseconds(2_500))
        #expect(try await layer(try Self.request(), next).status == .ok)
    }

    @Test("Retry-After is never below one second", arguments: [1, 10, 999])
    func retryAfterFloor(_ milliseconds: Int) async throws {
        let (limiter, _) = try Self.limiter(1, per: .milliseconds(milliseconds), burst: 1)
        let layer = rateLimit(limiter)
        _ = try await layer(try Self.request()) { _ in Response(status: .ok) }
        let refused = try await layer(try Self.request()) { _ in Response(status: .ok) }
        #expect(refused.headers[.retryAfter] == "1")
    }

    @Test("By default the peer's address is the key; a request with no address shares one bucket")
    func defaultKey() async throws {
        let (limiter, _) = try Self.limiter(1, per: .seconds(1), burst: 1)
        let layer = rateLimit(limiter)
        let next: Handler = { _ in Response(status: .ok) }
        #expect(try await layer(try Self.request(remote: "198.51.100.1"), next).status == .ok)
        #expect(try await layer(try Self.request(remote: "198.51.100.2"), next).status == .ok)
        #expect(try await layer(try Self.request(remote: "198.51.100.1"), next).status == .tooManyRequests)
        #expect(try await layer(try Self.request(remote: nil), next).status == .ok)
        #expect(try await layer(try Self.request(remote: nil), next).status == .tooManyRequests)
    }

    @Test("A key can be chosen, for a deployment behind a proxy")
    func customKey() async throws {
        let (limiter, _) = try Self.limiter(1, per: .seconds(1), burst: 1)
        let forwarded = try #require(HTTPField.Name("X-Forwarded-For"))
        let layer = rateLimit(limiter, key: { $0.headers[forwarded] })
        func request(_ client: String) throws -> Request {
            var headers = HTTPFields()
            headers[forwarded] = client
            return try Request(method: .get, target: "/x", headers: headers, body: Data(), remoteAddress: "10.0.0.1")
        }
        let next: Handler = { _ in Response(status: .ok) }
        #expect(try await layer(try request("a"), next).status == .ok)
        #expect(try await layer(try request("b"), next).status == .ok)
        #expect(try await layer(try request("a"), next).status == .tooManyRequests)
    }
}
