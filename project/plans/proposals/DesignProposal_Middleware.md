# Design Proposal: request id, access log, rate limiter

**Status:** Proposed and started 2026-10-28; the owner asked for the remaining roadmap to be finished with little
intervention, so the decisions below are mine, each with its reason, and are open to being reversed.

All three are `Middleware` values in the core (`SwiftHTTPService`): no NIO, no sockets, testable without a network.
Time is injected, so the tests are deterministic. Order, outermost first: access log, request id, rate limiter, the
rest. The log then sees the id and records the `429`s the limiter makes.

## 1. Request id
- `RequestID: ContextKey` (`String`) and `requestID(header:generate:)`.
- An incoming `X-Request-ID` is untrusted and ends up in logs. It is accepted only if it is 1 to 64 characters of
  `[A-Za-z0-9._-]`; anything else is replaced by a generated id, never cleaned or truncated (a cleaned id can
  collide with a real one). Default generator: a UUID.
- The id is put on the response whatever the handler set. A handler that throws has no response to put it on;
  the transport's `500` carries no id, and the id is still in the context for the access log.

## 2. Access log
- `AccessLogEntry`: method, path, status, response bytes, duration, request id, remote address. **Never** the
  query string, headers or body: a query can hold a token. `path` is the strict origin-form path the core already
  validated.
- `accessLog(clock:sink:)`: the sink is a `@Sendable` closure so the kit chooses no logging library. A handler that
  throws is logged as `500` and the error is rethrown unchanged; its text is never logged.
- `AccessLogEntry.line`: one line of `key=value` pairs, each value quoted and escaped (quotes, backslash, every
  control character as `\xNN`), so no value can start a second line or forge a field.

## 3. Rate limiter
- GCRA (the generic cell rate algorithm), in integer nanoseconds: no floating point to round, and one number per
  key. `RateLimit(requests:per:burst:)` is validated (requests and burst at least 1, the interval positive and at
  most a day, nothing clamped).
- `RateLimiter` is an actor holding the table: per-client key from a closure, default the remote address. Behind a
  proxy every client shares one address, so a deployment there must supply its own key; the doc says so.
- The table is bounded (`maximumKeys`, default 10,000). When it is full, idle keys (a full bucket) are dropped
  first; if none is idle the key with the oldest activity goes. A flood of new keys therefore costs a client its
  own history and cannot grow memory.
- A refused request is `429` as a problem (`rate_limited`) with `Retry-After` in whole seconds, rounded up, at
  least 1. The request is not passed on.
