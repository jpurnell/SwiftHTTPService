# SwiftHTTPService

A small, safe kit for serving a JSON API over HTTP/1.1 and TLS.

**Status:** 1.0.0-beta.3 (2026-11-13), private, feature complete for the workspace's hand-rolled servers; the API is frozen
for the 1.0 line pending the beta. What stands between this and 1.0.0 is in `project/master_plan.md` (a multi-day soak, and
SwiftTLSKit reaching 1.0). The core (request, response, problem, middleware, router, conditional requests, health route,
validated configuration, forms, cookies, redirects, streaming) and the transport (HTTP/1.1, and HTTP/2 over TLS, with
trusted proxies, the PROXY protocol, refusal hooks and TLS reload) exist and are tested. `ijs-dashboard-server` has served on it
since 2026-10-28 (Teletran 2). SwiftPushHub and FleetWatch have been migrated onto it (merged 2026-10-29; their deploys
are the owner's, per each repository's runbook). macOS 14 or newer is what is run in production; Linux (Swift 6.2) builds and passes the full test suite in CI, run serially (see Continuous integration).
Design: `project/plans/proposals/DesignProposal_SwiftHTTPService.md`.

## What it is

- `Request`: a parsed request. The target is parsed strictly and once: origin-form only, split into segments
  before percent-decoding, and anything ambiguous (dot segments, empty segments, a fragment, a bad escape, a
  decoded NUL) is refused rather than normalised.
- `Response`, `Problem`: JSON with sorted keys (so bytes are stable), and RFC 9457 problems with a stable
  `code`. Two problems built from the same inputs are the same bytes.
- `Handler`, `Middleware`, `wrap(_:with:)`: a request becomes a response; middleware wrap handlers.
- `Router`: `/a/{name}/b` patterns, whole-segment matching, no regexes or wildcards. A literal beats a
  parameter, leftmost first, whatever the registration order. Duplicate shapes and malformed patterns are
  refused at registration. `404` and `405` (with `Allow`) are problem details and can be replaced so a server
  can make its refusals indistinguishable. `HEAD` is served by `GET`.
- `EntityTag`, `Conditional`: `If-None-Match` as RFC 9110 defines it (weak comparison, `*`, lists); a value
  that does not parse matches nothing, so the answer is a full response and never a wrong `304`.
- `Router.addHealth()`: `GET /health` with a constant body that reveals nothing.
- `requestID(...)`: an id on every request and response. An id the caller offers is used only if it is 1 to 64
  characters of `A-Z a-z 0-9 . _ -`; otherwise a generated one replaces it, whole.
- `accessLog(sink:)`: an `AccessLogEntry` per request (method, path without its query, status, bytes, duration,
  id, peer) and a one-line `key=value` form in which no value can end its field or start another line. The
  query, headers and body are never recorded.
- `Response.html/.text/.javascript/.css/.png`: the type (with a charset for text) and `nosniff`. `Response.redirect`: a
  path-absolute reference or a named origin matched whole, so a redirect built from input is never an open redirect.
  `Cookie`: validated against RFC 6265, `Secure`, `HttpOnly` and `SameSite=Lax` by default, and the `__Host-` and
  `__Secure-` rules enforced; `Request.cookies` reads leniently and never throws.
- `Request.form()`: `application/x-www-form-urlencoded`, strictly (a `%` needs two hex digits, a raw space or control
  byte is refused, bounded fields, duplicates kept in order).
- `Request.httpVersion` and `Request.peerAddress`: which version carried a request, and the socket's peer when a
  trusted proxy reported a different client in `remoteAddress`.
- `Response.streaming(status:headers:produce:)` and `Response.eventStream`: a body written while it is sent, with
  backpressure, and server-sent events written strictly (a name, id or comment with a line break is refused).
- `Router.add(..., maximumBodyBytes:, middleware:)`: a body bound and layers for one route.
- `RateLimiter`, `rateLimit(_:key:)`: a per-client limit (GCRA, integer nanoseconds, one number per client) with
  a bounded table, `429` as a problem with `Retry-After`. Behind a proxy, key on what the proxy reports.
  Order, outermost first: access log, request id, rate limiter, the rest.
- `RateLimiterGroup`, `RateBudget`, `RateClaim`: one request against **several budgets, all or nothing** (see below).
- `allowedHosts(_:)`: `421 Misdirected Request` unless `Host` (`:authority` over HTTP/2), port included, is on a list of
  exact, ASCII-case-insensitive `host` or `host:port` entries. It is the defence against DNS rebinding **on a loopback bind**;
  on a public bind the TLS name plus a `Host` check is the caller's decision. An empty list or a malformed entry throws.
- `cors(allowedOrigins:allowedMethods:allowedHeaders:)`: strict CORS. Entries are serialized origins compared byte for byte
  (`*`, `null`, paths and uppercase schemes are refused at construction); an origin not listed is `403`; a listed one is echoed
  (never a wildcard) on the response, streaming included, with `Vary: Origin`; a preflight is answered `204` by the middleware
  without calling the handler. Put it **before authentication** and after `allowedHosts`.

## The transport (`SwiftHTTPServiceNIO`)

```swift
let configuration = try ServiceConfiguration(port: 8443, tls: TLSFiles(certificateChainPath: "...", privateKeyPath: "..."))
let server = HTTPServer(configuration: configuration) { request in try .json(["hello": "world"]) }
let address = try await server.start()      // the port actually bound (port 0 asks the system for one)
await server.shutdown()                     // graceful: drains, then closes after the grace period
```

HTTP/1.1 over TCP, and over TLS (1.2 or newer) HTTP/2 as well, picked by ALPN (`ServiceConfiguration.protocols`
narrows it to HTTP/1.1; plaintext is always HTTP/1.1, with no `h2c`). `ServiceConfiguration` holds the
certificate and key as **paths**; the identity is loaded, judged and reloaded by the owner's **SwiftTLSKit**:
a missing or unreadable file, a key others can read, a key that does not match, an empty or invalid chain
and an expired leaf each stop `start()` with `HTTPServerError.tlsIdentity(...)` carrying SwiftTLSKit's typed
error (it names the path, never the contents), and the server can be started again once they are fixed.
`server.reloadTLS()` takes a renewed certificate without a restart (new connections get it, open ones are
untouched; unfit files leave the old identity serving and say so). To reload on a signal or a timer, run
`server.reloadTLS(onEach: TLSReloadTrigger.hangup(), mode: .always, report: ...)` (or
`TLSReloadTrigger.every(...)` with `.ifChanged`) in a task; it survives a restart of the server. **Plaintext is for loopback**: the host
defaults to `127.0.0.1`, and a host SwiftTLSKit's `BindExposure` calls exposed (`0.0.0.0`, a name, a LAN
address) with no TLS identity is `HTTPServerError.exposedPlaintext`. Every limit in `Limits` is enforced, and
none is clamped; a value out of range makes `ServiceConfiguration` throw an error that names the field and
not the value.

| Limit | Default | Range | What happens when it is hit |
|---|---|---|---|
| `maximumHeaderBytes` | 16 KiB | 1 KiB to 1 MiB | `431`, close. Counted as the bytes arrive, request line included |
| `maximumHeaderCount` | 100 | 1 to 1000 | `431`, close |
| `maximumBodyBytes` | 1 MiB | 0 to 64 MiB | `413`, close. Checked against `Content-Length` before any body is read |
| `headerReadTimeout` | 10 s | up to 1 h | `408`, close. A deadline on the whole head from its first byte, so dripping bytes does not extend it |
| `bodyReadTimeout` | 30 s | up to 1 h | `408`, close |
| `idleTimeout` | 60 s | up to 1 h | between requests: close, nothing written. On a new connection that has sent nothing: `408`, close |
| `maximumConnections` | 256 | 1 to 100,000 | plaintext: `503` with `Retry-After`, close, without reading the request (at most 32 such refusals at once, each for at most 2 s; one past that is closed with nothing written). TLS: the same after the handshake, in HTTP/1.1 or as the first stream of an h2 connection (at most 8 at once). With the PROXY protocol over TLS: closed, nothing written |
| `busyRetryAfter` | 1 s | above 0, up to 1 h | the `Retry-After` of that `503`, rounded up to whole seconds |
| `shutdownGrace` | 10 s | 0 to 10 min | whatever is still open when it ends is closed |
| `maximumConcurrentStreams` | 100 | 1 to 1000 | HTTP/2 only. Advertised in SETTINGS and enforced; a stream past it is refused |
| `maximumStreamDuration` | 1 h | up to a day | a streaming response is cut off, whether its producer is writing or idle, and the producer is cancelled |
| `maximumStreamBytes` | 1 GiB | 1 to 1 TiB | the write that passes it is refused (`StreamError.byteLimit`) and the stream ends |
| `streamWriteTimeout` | 30 s | up to 1 h | one write that cannot finish (the peer does not read) ends the stream |

**Refused as ambiguous (`400`, close):** a `Content-Length` with a `Transfer-Encoding`; a duplicate, signed,
hexadecimal, listed or non-numeric `Content-Length`; any `Transfer-Encoding` other than exactly `chunked` (and
any on HTTP/1.0); a missing or duplicate `Host` on HTTP/1.1; a header value with CR, LF or NUL; folded lines and
bare line feeds (by NIO's parser); a target that is not strict origin-form (by the core's `Request`). A refusal
is a fixed `application/problem+json` body that never repeats anything the peer sent.

**Behind a proxy:** `ServiceConfiguration(trustedProxies:forwarding:)` names the proxies whose word is believed
(CIDR blocks, nothing trusted by default; the block of every address is refused) and how they speak:
`.xForwardedFor`, read from the right (the first address that is not itself a trusted proxy is the client), or
`.proxyProtocol` (version 1 or 2, read before TLS: required from a trusted peer, refused from anyone else who
begins with one). Forwarded information is believed only from a trusted peer. `ServiceConfiguration(connectionReuse:)`
can ask for `.closeAfterResponse`, for clients that cannot reuse a connection. `HTTPServer(refusals:)` gives the
transport's own refusals a body of the server's choosing (the status stays the transport's), and a record of each one (who
asked and, when it was read, the request line, escaped and cut short) for the log, and
`HTTPServer(configuration:router:)` wires each route's own body bound to the transport.

**Not supported, on purpose:** pipelining (the first request is answered with `Connection: close` and the second
is never run), `Upgrade`, `h2c`, client trailers, server push and HTTP/2 priorities. **Not bounded here:** the time a handler takes. A handler that never
returns keeps its connection open until it returns, the peer leaves, or a shutdown's grace period ends.

## Dependencies

The core needs `swift-http-types` and nothing else. The transport adds Apple's `swift-nio` and
`swift-nio-extras` (for `ServerQuiescingHelper`, which does the graceful shutdown), `swift-nio-http2` and the owner's
**SwiftTLSKit** (`1.0.0-beta.1`, by URL, pinned exactly; private), of the transport target only.
Resolving `swift-nio-extras` also resolves its own dependencies, one of which, `swift-service-lifecycle`, is
the Swift Server Workgroup's and not Apple's; nothing in this package links it.

## Develop

```bash
./scripts/bootstrap.sh      # once per clone: enables the git hooks
swift test
quality-gate
```

## Continuous integration

`.github/workflows/ci.yml` builds and tests on Linux (a `swift:6.2` container) and on macOS. Since 2026-11-10 both
jobs run and pass. Linux runs the tests serially (`--no-parallel`): the suite's timing tests use 300 ms limits over real sockets, and on a
two-core runner in parallel they measure the runner's load. The Linux job also runs the PROXY protocol check against the
distribution's HAProxy (2.8). The first Linux run found two defects (a refused client that was still sending could lose its
answer to a reset; `SIGHUP` was not delivered), both fixed in the 0.8.1 changes. The one private dependency, SwiftTLSKit (an SSH URL in `Package.swift`), needs a read-only
**deploy key** on that repository and its private half as the Actions secret `SWIFTTLSKIT_DEPLOY_KEY` on this one; the
steps are in the workflow's header comment. Pull requests from forks have no secrets and cannot resolve it.

## Licence

Proprietary. See `LICENSE`.

## Several budgets at once

A request that must pass a per-client budget and a per-address budget should spend neither when either refuses.
`RateLimiterGroup` holds the budgets in one actor and checks every claim before it writes any, so a refusal costs nothing
and `Retry-After` is the longest wait among the budgets that refused:

```swift
let group = try RateLimiterGroup([
    RateBudget(RateLimit(requests: 2, per: .seconds(1), burst: 120)),   // budget 0: per app key
    RateBudget(RateLimit(requests: 30, per: .seconds(60))),             // budget 1: per address bucket
])
switch try await group.admit([RateClaim(budget: 0, key: appKey), RateClaim(budget: 1, key: bucket)]) {
case .allowed: break                                                    // both were spent
case .limited(let wait, let refusedBy): break                           // neither was; `refusedBy` says which refused
}
```

Each budget's table is bounded by its own `maximumKeys`. Keys that are not real (an unrecognised app key) should be mapped
by the caller to one fixed key before claiming, so they share one slot and one budget and cannot spend a real key's.
The clock is injectable: `now:` (synchronous) or `clock:` (asynchronous).
