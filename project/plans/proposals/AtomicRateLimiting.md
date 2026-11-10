# Design Proposal: Atomic rate limiting (one limiter implementation for the portfolio)

**Status:** PROPOSED 2026-11-09. Owner decision (2026-11-09): extend the kit so SwiftDiagnosticsHub, and the other servers, keep **one** rate-limiter implementation. Target version **0.8.0**, additive.

**Facts marked (repo) were read on 2026-11-09. Anything not checked is marked *unverified*.**

---

## 1. Objective

Let one request be checked against **several budgets at once, all or nothing**: it is admitted and every budget is spent, or it is refused and none is. The refusal's `Retry-After` is the longest wait among the budgets that refused. Master plan: the road to 1.0.0 and the migration of the hand-rolled servers (`MigrationPlan_HandRolledServers.md`); this removes the last reason a consumer wrote its own limiter.

## 2. Motivation

- SwiftDiagnosticsHub (repo, `Sources/SwiftDiagnosticsHubKit/RateLimiter.swift`) checks a request against a per-app-key budget and a per-address-bucket budget. Its `RateLimiterChoiceTests` (repo) documents why the kit's `RateLimiter` did not fit:
  1. **No refund.** `RateLimiter.check` spends when it says yes. Two limiters composed spend the key's token on a request the address bucket then refuses (the test shows `[true,false,false,false]` against the wanted `[true,false,false,true]`).
  2. **Clock.** The kit takes a synchronous `@Sendable () -> Duration`; the Hub's tests move an `async` `HubClock`.
  3. **Garbage keys** must share one budget so they can neither fill a table nor spend a real app's budget.
- Workaround today: a second, 130-line, `Double`-token-bucket implementation in the Hub, with its own eviction. Drawback: two algorithms, two sets of edge cases, floating point.

## 3. Proposed Architecture

**Modified:** `Sources/SwiftHTTPService/RateLimit.swift`. **New:** `Sources/SwiftHTTPService/RateLimiterGroup.swift`.

1. Extract the algorithm from the `RateLimiter` actor into an internal, non-isolated value type `RateTable` (a struct, `Sendable`): the `[String: Int]` of theoretical arrival times, the emission and tolerance, the bound, and three operations: `evaluate(key:at:)` (pure: returns `.allowed(next:)` or `.limited(wait:)`, mutates nothing), `commit(key:next:at:)` (stores, evicting if the table is full) and `count`.
2. `RateLimiter` becomes a thin actor around one `RateTable`: `check` = evaluate then commit. Same behaviour, same code path.
3. New `RateLimiterGroup` actor: owns an array of `RateTable`s (one per budget). `admit(_:)` reads the clock, **evaluates every claim without mutating**, and only if every claim passes commits them all. Because GCRA's state is the theoretical arrival time and a refused request never writes it, **no refund is needed**: check-then-commit is the whole mechanism.

**Concurrency decision.** The budgets live in **one actor**. The evaluate-all-then-commit-all section contains no `await`, so it is one isolated operation and no other caller can interleave. (Coordinating several `RateLimiter` actors would need an await between check and commit and would reintroduce the race.) The clock, if async, is read **before** the atomic section, once per call.

## 4. API Surface

```swift
/// One budget of a group: a rate and a table bound.
public struct RateBudget: Sendable, Hashable {
    public init(_ limit: RateLimit, maximumKeys: Int = 10_000) throws(RateLimitError)
}

/// One thing a request spends: a key in one of the group's budgets (by position in `init`).
public struct RateClaim: Sendable, Hashable {
    public init(budget: Int, key: String)
}

public enum RateAdmission: Equatable, Sendable {
    case allowed
    /// `retryAfter` is the longest wait among the refusing budgets; `refusedBy` lists their indices, ascending.
    case limited(retryAfter: Duration, refusedBy: [Int])
}

public enum RateClaimError: Error, Equatable, Sendable {
    case noBudgets            // an empty group
    case unknownBudget        // a claim names a budget that does not exist (never silently unlimited)
}

public actor RateLimiterGroup {
    public init(_ budgets: [RateBudget], now: (@Sendable () -> Duration)? = nil) throws(RateClaimError)
    public init(_ budgets: [RateBudget], clock: @escaping @Sendable () async -> Duration) throws(RateClaimError)
    public func admit(_ claims: [RateClaim]) throws(RateClaimError) -> RateAdmission
    public func trackedKeys(in budget: Int) -> Int?     // nil for an unknown budget
}
```

Semantics: no claim is spent unless all pass. Two claims for the same (budget, key) in one call are counted **once** (a request costs one token per budget). An empty claim list is allowed and spends nothing. Existing `RateLimiter`, `RateLimit`, `RateLimitError`, `rateLimit(_:key:)` are unchanged.

**Clock seam.** Keep `now:` (sync) on both types. The group adds `clock:` (async), because the Hub's clock is `async`; a sync closure adapts to it trivially, so one internal path (async) serves both. `RateLimiter` stays synchronous-clock only (its callers need nothing else; *the group is the type a consumer with an async clock uses*).

**Garbage keys.** Not an API: the caller maps an unrecognised key to one fixed sentinel key (the Hub already does: `unknownKeyBudget`) and the bounded table does the rest. A kit-side "fallback key" would need the kit to know which keys are recognised, which is the caller's data; adding a callback gains nothing over one line in the caller. Documented in the DocC and README, and pinned by a test (many distinct sentinel-mapped requests hold one table slot and spend only the shared budget).

## 5. MCP Schema

Not applicable: an in-process Swift API with no tool surface.

## 6. Constraints & Compliance

Swift 6 strict concurrency; no force unwraps, `try!`, force casts; guard clauses; integer nanoseconds (no `Double`, no `Int(Double)`, no `String(format:)`); DocC on every public symbol; no logging in the kit's types (so the logging checker has no catch to meet); no suppressions.

## 7. Source & API Compatibility

Additive: 0.8.0. Every existing `RateLimiter` test must pass **untouched** (the refactor is covered by them). `RateLimitError` gets no new case (a new case would break an exhaustive `switch`); the group's new errors are a new type. `RateLimiter.Decision` is unchanged.

## 8. Storage

In memory only, as before: one `[String: Int]` per budget.

## 9. Resource Budget

Per budget at most `maximumKeys` (1 to 10,000,000) entries, so a group's memory is the sum of its bounds; a flood of new keys cannot grow it. Eviction as today (idle keys first, then the earliest arrival time), O(n) only when a table is full and a new key arrives. *Unverified:* that this O(n) pass is acceptable at 10,000,000 keys under a flood; it is unchanged from the current limiter, and a bound of 10,000 (the default) costs microseconds.

## 10. Dependencies

None added.

## 11. Test Strategy

Tests are hand-worked from GCRA (T = emission interval, bucket = B*T) on a manual clock. Red first.
- All-or-nothing: budget A (burst 3), budget B (burst 1); two requests from the same B key: the second is refused by B, and **three further requests with a fresh B key are still all allowed against A's remaining tokens** (A was spent only twice in total over the run; asserted by the following request).
- Retry-After is the max of the refusals (A refuses with 2 s, B with 5 s: 5 s, `refusedBy == [0, 1]`); a single refusal reports only itself.
- Independent keys and independent budgets do not interfere.
- Table bound and eviction as `RateLimiter`'s (full table, idle first, then oldest; flood of 2,000 keys never exceeds the bound); a refused new key does not enter the table and does not evict.
- Refill on the injected clock (sync `now:` and async `clock:`).
- The sentinel pattern: 500 distinct garbage keys mapped to one key hold one slot and do not spend a real key's budget.
- Duplicate claims count once; empty claims allowed; unknown budget and empty group throw.
- Concurrency: 200 tasks against a frozen clock, budget capacity 50 (and a second budget with 20): admitted total is exactly 20, never above; with an advancing refill, never above capacity plus refill.
- A property check against the single-budget limiter: a group of one budget answers exactly as `RateLimiter` for a random sequence of keys and clock steps.
- Every pre-existing `RateLimiterTests` case unchanged.

## 12. Architecture Decision Review

Reviewed against `DesignProposal_Middleware.md`: the algorithm stays in one place (`RateTable`); the actor is the only isolation boundary; no new module. The decision between *`admit` across budgets* and a *`check`/`commit` split exposed to callers* is in §13.

## 13. Adversarial Review

- **Race between check and commit:** closed by one actor and no `await` between them (a test hammers it).
- **Async clock and reentrancy:** the clock is awaited before the atomic section, so a later caller can hold a *later* reading than an earlier caller that commits after it. A stale (earlier) reading can only make the check stricter (`max(stored, time)`), never over-admit. The clock must be monotonic, as before.
- **Duplicate or unknown claims** could silently spend twice or never: the first is collapsed and defined, the second throws.
- **Eviction inside an atomic admit:** commits happen after all checks, so eviction cannot change a decision already made in the same call. A commit that evicts a key a *later claim in the same call* uses is possible only for two claims in the same budget; evaluation is complete by then, so it is harmless.
- **Wait of zero:** a refusal always waits at least a nanosecond (as today), so `Retry-After` never rounds to zero.

## 14. Alternatives Considered

- **`check`/`commit` on `RateLimiter` for callers to compose.** Rejected: composition across two actors has an `await` between the halves; a concurrent caller can pass the first check and be refused at commit, or two can both pass and over-spend. It moves the atomicity burden to every caller.
- **Refund (`give back`).** Rejected: with GCRA a refund is `arrival -= T`, racy across actors, and wrong after eviction.
- **Make `RateLimiter` itself multi-budget.** Rejected: changes the existing type's shape; additive is the bar.
- **A fallback-key parameter.** Rejected, see §4.

## 15. Future Directions

- `rateLimit(group:claims:)` middleware that builds claims from a `Request` and answers 429 with the longest `Retry-After` (not in 0.8.0: the Hub builds its claims from a parsed header, and the shape is not yet proven by a second consumer).
- Weighted claims (a request that costs more than one token): not needed by any listed consumer.

## 16. Open Questions

1. Naming (`RateLimiterGroup`, `RateBudget`, `RateClaim`): the owner may prefer others. Cheap to change before 0.8.0 is tagged.
2. Should `RateLimiter` also take an async clock? Not done: nothing needs it.

## 17. Documentation Strategy

DocC on every public symbol; a README section "Several budgets at once"; CHANGELOG 0.8.0; master plan.

---

### Migration (nothing is moved by this change)

**SwiftDiagnosticsHub** (repo, read-only): replace `SwiftDiagnosticsHubKit.RateLimiter` with a `RateLimiterGroup` of two budgets (key: `RateLimit(requests: 120, per: .seconds(60), burst: 120)` is the 120-capacity, 2/s bucket; address bucket 30 at 0.5/s: `requests: 30, per: .seconds(60)`), `clock:` adapting `HubClock.now()`, claims `[RateClaim(budget: 0, key: appKeyOrUnknownSentinel), RateClaim(budget: 1, key: bucket)]`, `.limited(retryAfter:refusedBy:)` mapped to the existing 429 and scope log (`refusedBy.contains(0)` is `key`). Delete its `RateLimiter.swift`, `RateLimiterChoiceTests`. Differences to accept: GCRA integer nanoseconds replace `Double` tokens; `Retry-After` is the exact wait to the next token (the Hub's `(1 - tokens) / rate` is the same quantity); the Hub hashes the address bucket (`Hasher` seed) before keying: keep doing that in the caller.

**Other limiters (listed from earlier survey, *unverified, not re-read for this proposal*):** SwiftPushHub `TokenAttemptLimiter`, `TokenRateLimiter`, `EnrollmentRateLimiter` (per-token and per-address limits: the same two-budget shape, likely movable); SwiftIdentity `TokenBuckets` (probably movable if keyed by string); FleetWatch, ijs-dashboard-server, concordance (check whether each limits per client with a bound, and whether any needs a lockout rather than a rate: a lockout is not GCRA and would stay). Each needs reading before a verdict.
