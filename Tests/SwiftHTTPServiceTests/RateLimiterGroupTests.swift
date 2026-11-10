import Foundation
import Testing
@testable import SwiftHTTPService

/// Several budgets checked all or nothing. Every expected number is worked out by hand from the generic cell rate
/// algorithm (one request costs an emission interval T; a bucket of B requests tolerates B*T), not read back from the code.
@Suite("Rate limiter group")
struct RateLimiterGroupTests {

    /// A clock the test moves by hand.
    // Justification: every read and write of the elapsed time happens inside the lock.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var elapsed = Duration.zero
        func now() -> Duration { lock.withLock { elapsed } }
        func advance(_ by: Duration) { lock.withLock { elapsed += by } }
    }

    private static func budget(_ requests: Int, per interval: Duration, burst: Int? = nil, keys: Int = 10_000) throws -> RateBudget {
        try RateBudget(try RateLimit(requests: requests, per: interval, burst: burst), maximumKeys: keys)
    }

    private static func group(_ budgets: [RateBudget], clock: Clock = Clock()) throws -> (RateLimiterGroup, Clock) {
        (try RateLimiterGroup(budgets, now: { clock.now() }), clock)
    }

    private static func claims(_ key: String, _ address: String) -> [RateClaim] {
        [RateClaim(budget: 0, key: key), RateClaim(budget: 1, key: address)]
    }

    // MARK: All or nothing

    @Test("A request the second budget refuses leaves the first budget unspent")
    func refusalSpendsNothing() async throws {
        // Budget 0: three at once, almost no refill (T = 1 hour). Budget 1: one at once.
        let (group, _) = try Self.group([try Self.budget(1, per: .seconds(3_600), burst: 3), try Self.budget(1, per: .seconds(3_600), burst: 1)])
        var answers: [Bool] = []
        for address in ["noisy", "noisy", "noisy", "quiet"] {
            answers.append(try await group.admit(Self.claims("k", address)) == .allowed)
        }
        // The two refused "noisy" requests spent nothing from "k", so "k" has been charged twice (noisy, quiet): one token left.
        #expect(answers == [true, false, false, true])
        #expect(try await group.admit(Self.claims("k", "third")) == .allowed)      // the third token
        #expect(try await group.admit(Self.claims("k", "fourth")) != .allowed)     // and now it is spent
    }

    @Test("A request the first budget refuses leaves the second budget unspent")
    func firstRefusalSpendsNothing() async throws {
        let (group, _) = try Self.group([try Self.budget(1, per: .seconds(3_600), burst: 1), try Self.budget(1, per: .seconds(3_600), burst: 2)])
        #expect(try await group.admit(Self.claims("k", "a")) == .allowed)
        #expect(try await group.admit(Self.claims("k", "a")) != .allowed)          // "k" is spent; "a" must not be charged for it
        #expect(try await group.admit(Self.claims("j", "a")) == .allowed)          // "a" has its second token
        #expect(try await group.admit(Self.claims("i", "a")) != .allowed)          // and only now is "a" spent
    }

    @Test("Retry-After is the longest wait among the budgets that refused, and the refusing budgets are named")
    func longestWaitWins() async throws {
        let clock = Clock()
        // Budget 0: T = 2 s, burst 1. Budget 1: T = 5 s, burst 1. Budget 2: T = 1 s, burst 5 (never refuses here).
        let (group, _) = try Self.group(
            [try Self.budget(1, per: .seconds(2), burst: 1), try Self.budget(1, per: .seconds(5), burst: 1), try Self.budget(1, per: .seconds(1), burst: 5)],
            clock: clock)
        let all = [RateClaim(budget: 0, key: "k"), RateClaim(budget: 1, key: "a"), RateClaim(budget: 2, key: "x")]
        #expect(try await group.admit(all) == .allowed)
        #expect(try await group.admit(all) == .limited(retryAfter: .seconds(5), refusedBy: [0, 1]))
        clock.advance(.seconds(1))
        #expect(try await group.admit(all) == .limited(retryAfter: .seconds(4), refusedBy: [0, 1]))
        clock.advance(.seconds(1))                                                  // budget 0 is due again; budget 1 is 3 s away
        #expect(try await group.admit(all) == .limited(retryAfter: .seconds(3), refusedBy: [1]))
        clock.advance(.seconds(3))
        #expect(try await group.admit(all) == .allowed)
    }

    @Test("Asking again after the told wait is allowed: a refusal costs nothing")
    func waitIsHonest() async throws {
        let clock = Clock()
        let (group, _) = try Self.group([try Self.budget(1, per: .seconds(2), burst: 1), try Self.budget(1, per: .seconds(3), burst: 1)], clock: clock)
        #expect(try await group.admit(Self.claims("k", "a")) == .allowed)
        for _ in 0..<20 { #expect(try await group.admit(Self.claims("k", "a")) == .limited(retryAfter: .seconds(3), refusedBy: [0, 1])) }
        clock.advance(.seconds(3))
        #expect(try await group.admit(Self.claims("k", "a")) == .allowed)
    }

    @Test("Keys and budgets are independent")
    func independence() async throws {
        let (group, _) = try Self.group([try Self.budget(1, per: .seconds(60), burst: 1), try Self.budget(1, per: .seconds(60), burst: 1)])
        #expect(try await group.admit(Self.claims("k1", "a1")) == .allowed)
        #expect(try await group.admit(Self.claims("k2", "a2")) == .allowed)
        #expect(try await group.admit(Self.claims("k1", "a3")) != .allowed)       // k1 spent
        #expect(try await group.admit(Self.claims("k3", "a1")) != .allowed)       // a1 spent
        #expect(try await group.admit([RateClaim(budget: 0, key: "a1")]) == .allowed)   // budget 0 never saw "a1"
    }

    @Test("Refill over time on the injected synchronous clock")
    func refill() async throws {
        let (group, clock) = try Self.group([try Self.budget(10, per: .seconds(1), burst: 5)])         // T = 100 ms
        let claim = [RateClaim(budget: 0, key: "k")]
        for _ in 0..<5 { #expect(try await group.admit(claim) == .allowed) }
        #expect(try await group.admit(claim) == .limited(retryAfter: .milliseconds(100), refusedBy: [0]))
        clock.advance(.milliseconds(99))
        #expect(try await group.admit(claim) == .limited(retryAfter: .milliseconds(1), refusedBy: [0]))
        clock.advance(.milliseconds(1))
        #expect(try await group.admit(claim) == .allowed)
    }

    @Test("An asynchronous clock drives the group the same way")
    func asyncClock() async throws {
        let clock = Clock()
        let group = try RateLimiterGroup([try Self.budget(10, per: .seconds(1), burst: 1)], clock: {
            await Task.yield()
            return clock.now()
        })
        let claim = [RateClaim(budget: 0, key: "k")]
        #expect(try await group.admit(claim) == .allowed)
        #expect(try await group.admit(claim) == .limited(retryAfter: .milliseconds(100), refusedBy: [0]))
        clock.advance(.milliseconds(100))
        #expect(try await group.admit(claim) == .allowed)
    }

    @Test("A group of one budget answers exactly as the single limiter does, over a long mixed sequence")
    func matchesSingleLimiter() async throws {
        let clock = Clock()
        let limit = try RateLimit(requests: 7, per: .seconds(1), burst: 3)
        let single = try RateLimiter(limit, maximumKeys: 4, now: { clock.now() })
        let group = try RateLimiterGroup([try RateBudget(limit, maximumKeys: 4)], now: { clock.now() })
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for _ in 0..<2_000 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407      // a fixed pseudo-random sequence
            let key = "k\((state >> 33) % 6)"
            clock.advance(.milliseconds(Int((state >> 20) % 90)))
            let expected = await single.check(key: key)
            let actual = try await group.admit([RateClaim(budget: 0, key: key)])
            switch (expected, actual) {
            case (.allowed, .allowed): break
            case (.limited(let a), .limited(let b, let by)): #expect(a == b && by == [0])
            default: Issue.record("the group and the limiter disagreed")
            }
            #expect(await single.trackedKeys == (await group.trackedKeys(in: 0)))
        }
    }

    // MARK: Claims

    @Test("The same key claimed twice in one call is one request; an empty claim list spends nothing")
    func duplicatesAndEmpty() async throws {
        let (group, _) = try Self.group([try Self.budget(1, per: .seconds(3_600), burst: 2)])
        let twice = [RateClaim(budget: 0, key: "k"), RateClaim(budget: 0, key: "k")]
        #expect(try await group.admit(twice) == .allowed)
        #expect(try await group.admit([]) == .allowed)
        #expect(try await group.admit(twice) == .allowed)      // a burst of two: each call cost one
        #expect(try await group.admit(twice) != .allowed)
    }

    @Test("A claim on a budget that does not exist is an error, and nothing is spent; an empty group is refused")
    func misuse() async throws {
        let (group, _) = try Self.group([try Self.budget(1, per: .seconds(3_600), burst: 1)])
        await #expect(throws: RateClaimError.unknownBudget) {
            try await group.admit([RateClaim(budget: 0, key: "k"), RateClaim(budget: 1, key: "x")])
        }
        await #expect(throws: RateClaimError.unknownBudget) { try await group.admit([RateClaim(budget: -1, key: "x")]) }
        #expect(try await group.admit([RateClaim(budget: 0, key: "k")]) == .allowed)      // "k" was not spent by the failed call
        #expect(await group.trackedKeys(in: 5) == nil)
        #expect(throws: RateClaimError.noBudgets) { try RateLimiterGroup([]) }
    }

    @Test("A budget's table bound is validated like the limiter's")
    func budgetValidation() {
        #expect(throws: RateLimitError.maximumKeys) { try RateBudget(try RateLimit(requests: 1, per: .seconds(1)), maximumKeys: 0) }
        #expect(throws: RateLimitError.maximumKeys) { try RateBudget(try RateLimit(requests: 1, per: .seconds(1)), maximumKeys: 10_000_001) }
    }

    // MARK: The tables are bounded

    @Test("With a table of three, a fourth active key evicts the one least recently active, and the table never grows")
    func evictsOldest() async throws {
        let (group, clock) = try Self.group([try Self.budget(1, per: .seconds(10), burst: 1, keys: 3)])
        for key in ["a", "b", "c"] {
            #expect(try await group.admit([RateClaim(budget: 0, key: key)]) == .allowed)
            clock.advance(.milliseconds(1))
        }
        #expect(await group.trackedKeys(in: 0) == 3)
        #expect(try await group.admit([RateClaim(budget: 0, key: "d")]) == .allowed)
        #expect(await group.trackedKeys(in: 0) == 3)
        #expect(try await group.admit([RateClaim(budget: 0, key: "a")]) == .allowed)       // evicted, so a full bucket again
        #expect(try await group.admit([RateClaim(budget: 0, key: "c")]) != .allowed)
    }

    @Test("Idle keys are dropped before an active one is")
    func idleKeysGoFirst() async throws {
        let (group, clock) = try Self.group([try Self.budget(1, per: .seconds(1), burst: 1, keys: 3)])
        for key in ["a", "b", "c"] { _ = try await group.admit([RateClaim(budget: 0, key: key)]) }
        clock.advance(.seconds(5))
        #expect(try await group.admit([RateClaim(budget: 0, key: "d")]) == .allowed)
        #expect(await group.trackedKeys(in: 0) == 1)
    }

    @Test("A flood of distinct keys never holds more than each budget's bound")
    func flood() async throws {
        let (group, clock) = try Self.group([try Self.budget(1, per: .seconds(60), burst: 1, keys: 100), try Self.budget(1, per: .seconds(60), burst: 1, keys: 50)])
        for index in 0..<2_000 {
            _ = try await group.admit(Self.claims("k\(index)", "a\(index)"))
            clock.advance(.microseconds(1))
            let first = try #require(await group.trackedKeys(in: 0))
            let second = try #require(await group.trackedKeys(in: 1))
            #expect(first <= 100)
            #expect(second <= 50)
        }
    }

    @Test("A refused request does not enter a table or evict anything")
    func refusedDoesNotEvict() async throws {
        let (group, _) = try Self.group([try Self.budget(1, per: .seconds(3_600), burst: 1, keys: 2), try Self.budget(1, per: .seconds(3_600), burst: 1)])
        #expect(try await group.admit(Self.claims("a", "x")) == .allowed)
        #expect(try await group.admit(Self.claims("b", "y")) == .allowed)
        #expect(try await group.admit(Self.claims("c", "x")) != .allowed)          // budget 1 refuses "x"; "c" must not push "a" out
        #expect(await group.trackedKeys(in: 0) == 2)
        #expect(try await group.admit(Self.claims("a", "z")) != .allowed)          // "a" is still remembered as spent
    }

    @Test("Garbage keys mapped to one fixed key share one slot and one budget, and spend nothing of a real key's")
    func garbageKeysShareOneBudget() async throws {
        let (group, _) = try Self.group([try Self.budget(1, per: .seconds(3_600), burst: 2, keys: 10), try Self.budget(1, per: .seconds(3_600), burst: 1_000)])
        let sentinel = "\u{0}unknown-key"
        var allowed = 0
        for index in 0..<500 {
            if try await group.admit(Self.claims(sentinel, "a\(index)")) == .allowed { allowed += 1 }
        }
        #expect(allowed == 2)                                                      // the shared budget's burst, no more
        #expect(await group.trackedKeys(in: 0) == 1)                               // one slot, not 500
        #expect(try await group.admit(Self.claims("real-app", "fresh")) == .allowed)
        #expect(try await group.admit(Self.claims("real-app", "fresh2")) == .allowed)   // the real key's own burst of two is intact
    }

    // MARK: Concurrency

    @Test("Many tasks at once never admit more than the tightest budget holds (frozen clock: exactly that many)")
    func concurrentFrozen() async throws {
        let (group, _) = try Self.group([try Self.budget(1, per: .seconds(3_600), burst: 50), try Self.budget(1, per: .seconds(3_600), burst: 20)])
        let admitted = await withTaskGroup(of: Bool.self, returning: Int.self) { tasks in
            for _ in 0..<300 {
                tasks.addTask { (try? await group.admit(Self.claims("k", "a"))) == .allowed }
            }
            var count = 0
            for await ok in tasks where ok { count += 1 }
            return count
        }
        #expect(admitted == 20)
        // The 280 refusals spent nothing: the first budget lost exactly 20 of its 50, so 30 remain for other addresses.
        var rest = 0
        for index in 0..<100 {
            if try await group.admit(Self.claims("k", "other\(index)")) == .allowed { rest += 1 }
        }
        #expect(rest == 30)
    }

    @Test("Many tasks on the real clock never admit more than capacity plus what refilled")
    func concurrentRealClock() async throws {
        let limit = try RateLimit(requests: 100, per: .seconds(1), burst: 20)               // T = 10 ms
        let group = try RateLimiterGroup([try RateBudget(limit), try RateBudget(limit)])
        let start = ContinuousClock.now
        let admitted = await withTaskGroup(of: Bool.self, returning: Int.self) { tasks in
            for _ in 0..<2_000 {
                tasks.addTask { (try? await group.admit(Self.claims("k", "a"))) == .allowed }
            }
            var count = 0
            for await ok in tasks where ok { count += 1 }
            return count
        }
        let elapsed = start.duration(to: ContinuousClock.now)
        let milliseconds = Int(elapsed.components.seconds) * 1_000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        #expect(admitted >= 20)
        #expect(admitted <= 20 + milliseconds / 10 + 1)
    }
}
