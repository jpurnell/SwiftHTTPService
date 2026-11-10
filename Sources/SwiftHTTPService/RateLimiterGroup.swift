// RateLimiterGroup.swift
// SwiftHTTPService
//
// Several rate budgets checked all or nothing.

/// One budget of a ``RateLimiterGroup``: a rate, and how many keys its table may hold.
public struct RateBudget: Sendable, Hashable {
    /// The rate.
    public let limit: RateLimit
    /// The most keys tracked at once.
    public let maximumKeys: Int

    /// Creates a budget.
    ///
    /// - Parameters:
    ///   - limit: The rate.
    ///   - maximumKeys: The most keys tracked at once. 1 to 10,000,000. Default 10,000.
    /// - Throws: ``RateLimitError/maximumKeys`` if the bound is out of range. Nothing is clamped.
    public init(_ limit: RateLimit, maximumKeys: Int = 10_000) throws(RateLimitError) {
        guard (1...10_000_000).contains(maximumKeys) else { throw .maximumKeys }
        self.limit = limit
        self.maximumKeys = maximumKeys
    }
}

/// One thing a request spends: a key in one budget of a ``RateLimiterGroup``.
public struct RateClaim: Sendable, Hashable {
    /// The position of the budget in the group's initialiser, from 0.
    public let budget: Int
    /// Whose budget it is: an app key, an address bucket, or a fixed key shared by everything unrecognised.
    public let key: String

    /// Creates a claim.
    public init(budget: Int, key: String) {
        self.budget = budget
        self.key = key
    }
}

/// The answer for one request checked against several budgets.
public enum RateAdmission: Equatable, Sendable {
    /// Every budget had room, and every one was spent.
    case allowed
    /// At least one budget had none, and **none** was spent. `retryAfter` is the longest wait among the budgets that
    /// refused, so asking again after it can succeed; `refusedBy` holds the positions of those budgets, ascending.
    case limited(retryAfter: Duration, refusedBy: [Int])
}

/// A group or a claim that cannot be used. It carries no key.
public enum RateClaimError: Error, Equatable, Sendable {
    /// The group was given no budgets.
    case noBudgets
    /// A claim names a budget the group does not have. It is refused, never treated as unlimited.
    case unknownBudget
}

/// Several budgets, each with its own rate and its own bounded table, and one operation that checks a request against
/// any of them **all or nothing**.
///
/// The case it exists for is a request that must pass a per-client budget and a per-address budget: if the address
/// budget refuses, the client's budget must not have been charged. With the generic cell rate algorithm a refused
/// request never changes a key's state, so ``admit(_:)`` checks every claim first and writes only if every one passed;
/// nothing is ever given back.
///
/// **Isolation.** All the budgets live in this one actor, and the check of every claim and the writes that follow
/// run with no suspension between them, so no other caller can interleave. Composing several ``RateLimiter``
/// actors cannot give this: there is a suspension between one limiter's answer and the next.
///
/// **Memory.** Each budget holds at most its own `maximumKeys`, so the group's size is the sum of its bounds however
/// many distinct keys arrive. To keep keys that are not real (an unrecognised app key, say) from filling a table or
/// spending a real key's budget, the caller maps all of them to one fixed key before claiming: they then share one
/// slot and one budget.
///
/// ```swift
/// let appKey = "an-app-key"
/// let bucket = "an-address-bucket"
/// let group = try RateLimiterGroup([
///     RateBudget(RateLimit(requests: 2, per: .seconds(1), burst: 120)),   // 0: per app key
///     RateBudget(RateLimit(requests: 30, per: .seconds(60))),             // 1: per address bucket
/// ])
/// switch try await group.admit([RateClaim(budget: 0, key: appKey), RateClaim(budget: 1, key: bucket)]) {
/// case .allowed: break
/// case .limited(let wait, _): print("retry after", wait)
/// }
/// ```
public actor RateLimiterGroup {
    private let clock: @Sendable () async -> Duration
    private var tables: [RateTable]

    /// Creates a group whose clock is a synchronous reading.
    ///
    /// - Parameters:
    ///   - budgets: The budgets, numbered from 0 in this order. At least one.
    ///   - now: A monotonic reading, as the time since some fixed start. Nil means the process's `ContinuousClock`.
    /// - Throws: ``RateClaimError/noBudgets`` if `budgets` is empty.
    public init(_ budgets: [RateBudget], now: (@Sendable () -> Duration)? = nil) throws(RateClaimError) {
        let start = ContinuousClock.now
        let read: @Sendable () -> Duration = now ?? { start.duration(to: ContinuousClock.now) }
        try self.init(budgets, clock: { read() })
    }

    /// Creates a group whose clock is an asynchronous reading, for a caller whose time source is itself asynchronous.
    ///
    /// The clock is read once per ``admit(_:)``, before any budget is touched. It must be monotonic: a reading that
    /// goes backwards can only make a decision stricter, never let more through.
    ///
    /// - Parameters:
    ///   - budgets: The budgets, numbered from 0 in this order. At least one.
    ///   - clock: A monotonic reading, as the time since some fixed start.
    /// - Throws: ``RateClaimError/noBudgets`` if `budgets` is empty.
    public init(_ budgets: [RateBudget], clock: @escaping @Sendable () async -> Duration) throws(RateClaimError) {
        guard !budgets.isEmpty else { throw .noBudgets }
        self.tables = budgets.map { RateTable($0.limit, maximumKeys: $0.maximumKeys) }
        self.clock = clock
    }

    /// How many keys one budget tracks, or nil if the group has no such budget.
    public func trackedKeys(in budget: Int) -> Int? {
        guard tables.indices.contains(budget) else { return nil }
        return tables[budget].count
    }

    /// Checks a request against every claimed budget and spends all of them, or none.
    ///
    /// The same budget and key claimed twice count once. No claims at all is allowed and spends nothing.
    ///
    /// - Parameter claims: The budgets and keys the request spends.
    /// - Returns: ``RateAdmission/allowed``, or ``RateAdmission/limited(retryAfter:refusedBy:)`` with the longest wait.
    /// - Throws: ``RateClaimError/unknownBudget`` if a claim names a budget the group does not have; nothing is spent.
    public func admit(_ claims: [RateClaim]) async throws(RateClaimError) -> RateAdmission {
        for claim in claims where !tables.indices.contains(claim.budget) { throw .unknownBudget }
        let time = nanoseconds(await clock())
        // From here to the end there is no suspension: the check and the writes are one isolated step.
        var spend: [(claim: RateClaim, next: Int)] = []
        var longest = 0
        var refusedBy: Set<Int> = []
        for claim in Set(claims) {
            switch tables[claim.budget].evaluate(key: claim.key, at: time) {
            case .allowed(let next):
                spend.append((claim, next))
            case .limited(let wait):
                longest = max(longest, wait)
                refusedBy.insert(claim.budget)
            }
        }
        guard refusedBy.isEmpty else {
            return .limited(retryAfter: .nanoseconds(longest), refusedBy: refusedBy.sorted())
        }
        for item in spend { tables[item.claim.budget].commit(key: item.claim.key, next: item.next, at: time) }
        return .allowed
    }
}
