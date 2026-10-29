// RateLimit.swift
// SwiftHTTPService
//
// How fast one client may ask, kept in integer nanoseconds.

import HTTPTypes

/// A limit that was refused. It names the field and never a value.
public enum RateLimitError: Error, Equatable, Sendable {
    /// `requests` is outside 1 to 1,000,000, or too many for the interval (each must cost at least a nanosecond).
    case requests
    /// `interval` is not above zero and at most a day.
    case interval
    /// `burst` is outside 1 to 10,000.
    case burst
    /// `maximumKeys` is outside 1 to 10,000,000.
    case maximumKeys
}

/// How many requests one client may make in an interval, and how many at once.
///
/// `requests` per `interval` is the sustained rate; `burst` is how many may arrive together before the rate
/// holds. The limit uses the generic cell rate algorithm: one request costs `interval / requests` of credit
/// (the emission interval, T), and a bucket holds `burst * T`. All of it is whole nanoseconds, so there is no
/// floating point to round and one integer to keep for each client.
public struct RateLimit: Sendable, Equatable {
    /// The sustained number of requests per ``interval``.
    public let requests: Int
    /// The interval the rate is counted over.
    public let interval: Duration
    /// How many requests may arrive at once.
    public let burst: Int
    /// The cost of one request, in nanoseconds.
    let emissionNanoseconds: Int

    /// Creates a limit.
    ///
    /// - Parameters:
    ///   - requests: 1 to 1,000,000.
    ///   - interval: Above zero, at most a day, and at least a nanosecond for each request.
    ///   - burst: 1 to 10,000. Default: `requests`, or 10,000 if that is smaller.
    /// - Throws: ``RateLimitError`` for the first value out of range. Nothing is clamped.
    public init(requests: Int, per interval: Duration, burst: Int? = nil) throws(RateLimitError) {
        guard (1...1_000_000).contains(requests) else { throw .requests }
        guard interval > .zero, interval <= .seconds(86_400) else { throw .interval }
        let burst = burst ?? min(requests, 10_000)
        guard (1...10_000).contains(burst) else { throw .burst }
        let emission = nanoseconds(interval) / requests
        guard emission >= 1 else { throw .requests }
        self.requests = requests
        self.interval = interval
        self.burst = burst
        self.emissionNanoseconds = emission
    }
}

/// Counts requests per client, with a table that cannot grow past a bound.
///
/// When the table is full, clients that have nothing owed (their bucket is full again, so they would be treated
/// exactly as a client never seen) are dropped first; if there are none, the client that was least recently
/// active goes. A flood of new keys therefore costs a client its own history and cannot grow memory.
public actor RateLimiter {
    /// The answer for one request.
    public enum Decision: Equatable, Sendable {
        /// Let it through.
        case allowed
        /// Refuse it; the same client may try again after `retryAfter`.
        case limited(retryAfter: Duration)
    }

    private let emission: Int
    private let tolerance: Int
    private let maximumKeys: Int
    private let now: @Sendable () -> Duration
    /// The theoretical arrival time of each key's next request, in nanoseconds since the clock's start.
    private var arrival: [String: Int] = [:]

    /// Creates a limiter.
    ///
    /// - Parameters:
    ///   - limit: The rate.
    ///   - maximumKeys: The most clients tracked at once. 1 to 10,000,000. Default 10,000.
    ///   - now: A monotonic reading, as the time since some fixed start. Nil means the process's `ContinuousClock`.
    /// - Throws: ``RateLimitError/maximumKeys`` if the bound is out of range.
    public init(_ limit: RateLimit, maximumKeys: Int = 10_000, now: (@Sendable () -> Duration)? = nil) throws(RateLimitError) {
        guard (1...10_000_000).contains(maximumKeys) else { throw .maximumKeys }
        self.emission = limit.emissionNanoseconds
        self.tolerance = limit.burst * limit.emissionNanoseconds    // at most 10,000 * 86,400e9: well inside Int
        self.maximumKeys = maximumKeys
        let start = ContinuousClock.now
        self.now = now ?? { start.duration(to: ContinuousClock.now) }
    }

    /// How many clients are tracked.
    public var trackedKeys: Int { arrival.count }

    /// Asks whether `key` may make a request now, and counts it if so. A refused request costs nothing.
    public func check(key: String) -> Decision {
        let time = nanoseconds(now())
        let stored = arrival[key]
        let next = max(stored ?? time, time) + emission
        let earliest = next - tolerance
        guard time >= earliest else { return .limited(retryAfter: .nanoseconds(earliest - time)) }
        if stored == nil, arrival.count >= maximumKeys { makeRoom(at: time) }
        arrival[key] = next
        return .allowed
    }

    private func makeRoom(at time: Int) {
        arrival = arrival.filter { $0.value > time }
        guard arrival.count >= maximumKeys, let oldest = arrival.min(by: { ($0.value, $0.key) < ($1.value, $1.key) }) else { return }
        arrival.removeValue(forKey: oldest.key)
    }
}

/// Refuses requests from a client that is asking too fast: `429`, a `rate_limited` problem, and `Retry-After`
/// in whole seconds, rounded up and at least one. The handler is not run for a refused request.
///
/// - Parameters:
///   - limiter: The shared counter.
///   - key: Which client a request belongs to. By default the peer's address. **Behind a proxy every client has
///     the proxy's address**, so a deployment there must key on what the proxy reports (and trust only a proxy
///     it controls). A request with no key shares one bucket with the others that have none.
public func rateLimit(
    _ limiter: RateLimiter, key: @escaping @Sendable (Request) -> String? = { $0.remoteAddress }
) -> Middleware {
    { request, next in
        switch await limiter.check(key: key(request) ?? "\u{0}no key") {
        case .allowed:
            return try await next(request)
        case .limited(let wait):
            // A refusal always waits at least a nanosecond, so rounding up gives at least one second.
            let seconds = (nanoseconds(wait) + 999_999_999) / 1_000_000_000
            return try Response.problem(Problem(status: .tooManyRequests, code: "rate_limited")).retrying(after: seconds)
        }
    }
}

/// A non-negative duration as whole nanoseconds, rounded down.
private func nanoseconds(_ duration: Duration) -> Int {
    guard duration > .zero else { return 0 }
    let parts = duration.components
    return Int(parts.seconds) * 1_000_000_000 + Int(parts.attoseconds / 1_000_000_000)
}
