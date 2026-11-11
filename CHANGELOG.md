# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project will follow
[Semantic Versioning](https://semver.org/) from 0.1.0.

## [Unreleased]

## [1.0.0-beta.2] - 2026-11-11

Closes everything the beta.1 review left open, so the notes there headed "Known, and left as designed" are now fixed
except the two that are decisions (SwiftTLSKit's 0.x types; exhaustive enums).

### Fixed
- **`X-Forwarded-For` entries with a port or brackets were not believed.** `203.0.113.9:443`, `[2001:db8::9]` and
  `[2001:db8::9]:443` fell back to the proxy's address, so behind a proxy that writes them every client shared one
  rate-limit key and one ban (one abusive client could get the proxy throttled for all). The port and brackets are now
  read and dropped. Anything else stays unbelieved: a port that is not 1 to 5 digits or exceeds 65535, an empty or doubled
  port, an unbalanced bracket, brackets around an IPv4 address. An unbracketed IPv6 address is never split into address and
  port. This reverses the behaviour the 1.0.0-beta.1 notes list as "left as designed".
- **`redirect(to:allowing:)` refuses an `allowing` entry that is not an origin.** `"https:"` or `""` would have admitted
  every address; an entry must be `http` or `https` `://host[:port]` with no path, query, fragment or user information
  (host: a DNS name or a bracketed IPv6 literal; port: 1 to 65535). It throws the new `RedirectError.origin`, even when
  the location would not have matched. No consumer in the workspace calls it.
- **`Cookie` refuses a malformed `Domain`.** `.`, `a..b`, `example.com.`, a label starting or ending with a hyphen and a label
  over 63 characters were accepted and then ignored by the browser. One leading dot is still allowed (RFC 6265 ignores it).

### Added
- `Request.cookies(named:)`: every value sent for a name, in order. `cookie(named:)` still returns the first, which is right
  for path-scoped duplicates; the doc now says a cookie that carries trust should be `__Host-`, which a sibling subdomain
  cannot set, and that `cookies(named:)` shows when a name came twice.

### Changed
- `RedirectError` gained a case (`.origin`): a caller with an exhaustive `switch` over it needs one more branch.

## [1.0.0-beta.1] - 2026-11-11

The API is frozen for the 1.0 line, pending what the beta turns up. A final audit of the public surface and a review of the
trusted-proxy, `X-Forwarded-For`, redirect and cookie rules (by a reviewer with no part in writing them; not a human
outside the project) found no blocker; the fixes below came out of them.

### Changed (source-breaking only for a caller that reached for what was never meant to be called)
- `ResponseStream.discard()` and `NetworkBlock.canonicalAddress(octets:)` are `package` access, not `public`: they existed
  only for the sibling transport module. No consumer in the workspace used either.

### Fixed
- **`X-Forwarded-For` longer than 20 entries was attributed to the proxy.** A client behind a trusted, appending proxy could
  pad the header with commas to share the proxy's rate-limit key and escape a per-client ban. The rightmost 20 entries are
  now read; what is to their left is dropped, never believed, and cannot move the answer.
- **`X-Forwarded-For` addresses are canonical.** `::ffff:203.0.113.9` and `203.0.113.9` were two clients to a limit keyed on
  the result; the PROXY path already collapsed them.
- **`__Host-` and `__Secure-` prefixes are checked in any case**, as browsers match them (`__host-a` with a `Domain` was
  accepted here and dropped by the browser).

### Known, and left as designed (decisions for 1.0)
- `X-Forwarded-For` entries with a port (`203.0.113.9:443`) or brackets fail closed to the peer; a proxy that appends them
  (some Azure gateways) gets one key for every client. Accepting them is a feature, not a fix, and is not in the beta.
- `redirect(to:allowing:)` does not validate its `origins` entries (`"https:"` would admit any host); `Cookie` accepts a
  `Domain` with empty labels (`a..b`), which browsers ignore; `cookie(named:)` returns the first of duplicate names.
- Public API exposes `ReloadMode` and `ReloadOutcome` from SwiftTLSKit, which is still 0.x (`.upToNextMinor`), so a
  SwiftTLSKit minor can break this API's callers. **1.0.0 final should wait on SwiftTLSKit 1.0 or on types of this kit's own.**
- Public enums (`CookieError`, `TransportRefusal`, `Forwarding` and the rest) are exhaustive: a new case in a 1.x minor is
  source-breaking for a caller that switches over all of them without a default. Where that matters, write a `default`.
- Still unrun for 1.0.0: memory and descriptor growth over days (`Scripts/soak.sh`).

## [0.8.1] - 2026-11-10

First Linux CI run (Swift 6.2 container); it found two defects the macOS runs had not. Also new: the PROXY protocol check
ran against real HAProxy (3.4.7 locally, 2.8 in CI) and passed, and CI now runs it. No API change.

### Fixed
- **A refusal could be lost to a reset.** A response followed by `Connection: close` ended with a full close, and
  closing a socket that still holds unread request bytes (the body behind a refused head) sends a reset, which can
  destroy a response the client has not yet read. A client still sending saw a closed connection and no `400`/`413`/`431`.
  The output side is now shut down first, what the peer still sends is read and dropped, and the connection is closed
  when the peer ends it or after one second (`ConnectionHandler.lingerLimit`); a transport that cannot half-close is
  closed at once. Test: `RefusalIsReadTests` (a client that reads only after its body is sent; 19 of 20 rounds lost
  the response before the change).
- **`TLSReloadTrigger.hangup()` heard nothing on Linux.** A dispatch signal source there needs the signal blocked in
  every thread, and a process-directed `SIGHUP` landing on a thread that does not block it was lost. `SIGHUP` is now
  handled by a handler that writes to a self-pipe, read by a dispatch read source. While a hangup stream lives the
  signal's disposition is that handler (it was `SIG_IGN`); what was there before is still put back when the last
  stream ends.

## [0.8.0] - 2026-11-09

One rate-limiter implementation for the portfolio: a request against several budgets, all or nothing.

### Added
- **`RateLimiterGroup`: several rate budgets checked all or nothing.** A request is claimed against any number of
  budgets (`RateClaim(budget:key:)`, each budget a `RateBudget` with its own `RateLimit` and table bound). It is admitted
  and every budget is spent, or it is refused and none is. A refusal is `RateAdmission.limited(retryAfter:refusedBy:)`:
  the **longest** wait among the budgets that refused, and which budgets they were. No refund exists or is needed: a
  refused request never writes a key's generic-cell-rate state, so the group evaluates every claim and then writes.
  All the budgets live in one actor and the evaluate-and-write step has no suspension in it, so it is one isolated
  operation (composing several `RateLimiter` actors cannot give that). For SwiftDiagnosticsHub's per-app-key plus
  per-address-bucket case, and any server with the same shape. `project/plans/proposals/AtomicRateLimiting.md`.
- An asynchronous clock seam: `RateLimiterGroup(_:clock:)` takes `@Sendable () async -> Duration`; `RateLimiterGroup(_:now:)`
  takes the synchronous closure `RateLimiter` already takes. The clock is read once per `admit`, before any budget is touched.
- `RateClaimError` (`noBudgets`, `unknownBudget`): a claim on a budget that does not exist throws and spends nothing; it is
  never treated as unlimited. Two claims for the same budget and key in one call count once.

### Changed
- Internal only: the generic cell rate algorithm and its bounded table moved out of the `RateLimiter` actor into an internal
  value, `RateTable`, which the actor and the group share, so there is one implementation. `RateLimiter`'s API and behaviour
  are unchanged and its tests were not touched.

### Not changed, recorded
- Garbage keys that must share one budget (an unrecognised app key) are the caller's: map them to one fixed key before
  claiming. They then hold one table slot and one budget, which a test pins. A kit-side fallback would need the kit to know which keys are real.

## [0.7.0] - 2026-11-09

The shim removed, a connection past the cap told over TLS too, and the evidence for 1.0.0 merged: the rig that proves the
paths that had never been run. SwiftPushHub and FleetWatch have run on the kit since 0.4.1 with no transport fault.

### Changed (breaking)
- **The deprecated `ServiceConfiguration.connections` property and `connections:` initialiser label are removed** (renamed
  `connectionReuse` in 0.6.0, with a shim promised for one release). **FleetWatch**
  (`FleetService.swift`) still uses the old label and needs the one-word change before it takes 0.7.0.

### Added
- **A connection past `Limits.maximumConnections` is answered `503` with `Retry-After` over TLS as well.** After the
  handshake: an HTTP/1.1 peer gets the same bytes as in plaintext; an `h2` peer gets a connection that answers its first
  stream and sends `GOAWAY` (`BusyStreamHandler`). The hooks are called (`TransportRefusal.busy`; for `h2` when the first
  stream opens). The handshake is the cost 0.6.0 declined to spend (about 7.5 times a plaintext refusal), so the bound is
  tighter: at most **8** such refusals at once (plaintext 32), the handshake and the answer each held to 2 s. Behind the PROXY
  protocol over TLS a connection past the cap is still closed with nothing written (the header must be read before the
  handshake, and a refusal reads nothing). Reverses the 0.6.0 decision (A) by the owner's request.
- Tests that run the paths that had not been run: timeouts over a real socket, seeded fuzzing of the request target, form,
  cookie, CIDR, PROXY v1/v2 and the HTTP/1.1 head (no defect found), HTTP/2 floods and flow-control exhaustion and the cap
  under load (every defence held), a soak harness (`SOAK_SECONDS`, `Scripts/soak.sh`), TLS reload under traffic, the PROXY
  protocol behind HAProxy (config and script written, not run against HAProxy; the emulated path was run).
- A Linux and macOS CI workflow (`.github/workflows/ci.yml`), **not yet run**; it needs the deploy key described in the README.

### Fixed
- A test that expected a silent first connection to be closed with nothing written now expects the `408` 0.6.0 made it.

### Not changed, recorded
- Adding cases to `TransportRefusal` can break an exhaustive `switch` in a consumer (SwiftMoE has one); an enum in a
  non-resilient package cannot be made to grow safely, so this stays a consumer-side `default`, as the DocC says.

## [0.6.0] - 2026-10-30

The regression SwiftMoE's migration found, the other wire differences its replay found, and the public API audit that was
waiting for 1.0. The design and the audit table are `project/plans/proposals/DesignProposal_0.6.0.md`.

### Fixed
- **A connection past `Limits.maximumConnections` is told, not dropped (owner priority).** The hand-rolled server the kit
  replaced answered `503` with `Retry-After`; the kit closed such a connection with nothing written. In plaintext it now gets
  `503 Service Unavailable`, `application/problem+json` (code `service_unavailable`), `Retry-After` and `Connection: close`,
  written **without reading the request** (no parser, buffer or handler task), then the output side is shut and the input
  drained until the peer leaves or two seconds pass (closing with unread bytes sends a reset that can destroy the answer).
  Bounded: at most 32 connections are being refused at once, each lives at most 2 s, and one past that is closed with nothing
  written, as before. **Over TLS (and so HTTP/2) a connection past the cap is still closed before the handshake, nothing
  written and no hook called:** an answer needs the handshake, which measured about 7.5 times the CPU of a plaintext refusal
  (6.9 ms against 0.92 ms per connection, in-process, debug build), spent on exactly the connections there is no room for; an
  `h2` client could in any case only be answered with HTTP/2 frames. Put TLS in a proxy in front for clients that must be told.
  With the PROXY protocol the refusal does not read the balancer's header, so the `503` goes to the balancer.
- **A connection that connects and sends nothing is answered `408`** at `idleTimeout` (it was closed silently; the old server
  answered). A keep-alive connection that goes quiet after a request is still closed silently. A request whose body stops
  arriving was already answered `408` at `bodyReadTimeout`; what SwiftMoE saw closed was a peer that had gone, to which nothing
  can be written.
- **`HTTP/2.0` (any major version but 1) in an HTTP/1.1 request line is `505 HTTP Version Not Supported`**, not `400`.
  `HTTP/1.2`, `HTTP/2`, `HTTP/abc` stay `400`.
- **The `413` status line reads `Content Too Large`** (RFC 9110; NIO still says `Payload Too Large`). Also `416 Range Not
  Satisfiable` and `422 Unprocessable Content`, for a handler's own statuses as well.
- Left, with reasons: no `Host` on HTTP/1.1 stays `400` (RFC 9112); a body declared over the bound is `413` before any credential
  check, because a transport cannot read a credential from a body it refuses.

### Added
- `Limits.busyRetryAfter` (`Duration`, default 1 s, above zero and at most an hour), the `Retry-After` of that `503`, rounded
  up to whole seconds. `TransportRefusal.busy` (status 503, code `service_unavailable`), through `RefusalHooks` like the other
  transport refusals: `respond` shapes it (status and `Retry-After` stay the transport's), `observe` counts it, `record` sees
  it with the peer and **no request line**. `TransportRefusal.versionNotSupported` (505, `http_version_not_supported`).
- `RefusalRecord.init` is public, so a server's `record` function can be tested without a socket.

### Changed (audit; every change is source-compatible except the rename, which is shimmed)
- **`ServiceConfiguration.connections` is now `connectionReuse`**, for both the property and the initialiser label (it read as
  a count beside `maximumConnections`). The old names remain for **this release only** as `@available(*, deprecated, renamed:)`
  shims with unchanged behaviour, so SwiftPushHub, FleetWatch and ijs-dashboard-server compile unchanged (with a deprecation
  warning where `connections:` is used). They will be removed in 0.7.0 or at 1.0.0, whichever comes first.
- `Hashable` added to `TransportRefusal`, `RefusalRecord`, `BoundAddress`, `QueryItem`, `HTTPProtocolVersion`, `EntityTag`,
  `RateLimit`, `StreamError`, `Cookie.SameSite` and `ServiceConfiguration`'s `Forwarding`, `ConnectionReuse` and `Protocols`.
- `Request.init` throws `RequestError` (typed), like every other throwing initialiser in the kit.
- `maximumConnections`, `HTTPServer` and `TransportRefusal` documentation describe the busy refusal; `TransportRefusal` now says
  the set grows and a `switch` over it should end in `default`.

### Breaking, and what to do
- **An exhaustive `switch` over `TransportRefusal` without a `default` no longer compiles** (new cases `.busy` and
  `.versionNotSupported`). Of the four consumers only SwiftMoE has one (`ChatService.refusal(for:)`); it needs those two cases,
  or a `default`. SwiftPushHub, FleetWatch and ijs-dashboard-server compile unchanged.
- Behaviour: a silent new connection now receives a `408` where it was closed silently, and a connection over the cap in
  plaintext receives a `503` where it received nothing.

### Verified
- 493 tests (201 core, 292 transport); the new ones are real-socket tests of the refusal, its bounds, its hooks, TLS, the `408`,
  the `505` (including across packet splits and on a second request), and the phrases.
- **17 hand mutants of the new code, 16 killed, 1 equivalent.** Killed: cap boundary off by one; refusal cap removed; refusal
  cap off by one; `Retry-After` omitted (hooked body, and default body); `Retry-After` rounded down; hooks bypassed; record
  claiming a request line; no refusal deadline; no half-close after the write; refusal slot never released; TLS connections
  allowed to be refused; `Connection: close` omitted; `busyRetryAfter` not validated; a silent first connection closed silently;
  major version 3 not refused. **Equivalent:** forwarding a refused connection's bytes down the pipeline instead of dropping
  them (the handler is last, NIO's tail discards them).
- Consumers built against this working copy by a local-path override in scratch copies: SwiftPushHub, FleetWatch and
  ijs-dashboard-server compile unchanged; SwiftMoE fails at the one exhaustive `switch` described above and nowhere else.


## [0.5.0] - 2026-10-30

For the SwiftMoE migration (its `DesignProposal_HTTPServerOnSwiftHTTPService.md`). Nothing a caller of 0.4.1 writes
changes: two new middleware and new tests. The design is `project/plans/proposals/DesignProposal_0.5.0.md`.

### Added
- **`allowedHosts(_:)` (K1).** `421 Misdirected Request`, a problem with the code `misdirected_request`, unless the request's
  `Host` (an HTTP/2 `:authority` is already copied into it) is on a list of exact, ASCII-case-insensitive `host` or
  `host:port` entries. A bare `host` entry admits only a `Host` without a port. No `Host`, or two, is refused. It is for a
  **loopback bind** (DNS rebinding); on a public bind the TLS name plus the `Host` check is the caller's decision. Construction
  throws `AllowedHostsError` for an empty list, or (naming the position) an entry that is empty, holds whitespace, a control
  character or a byte outside ASCII, a scheme, path, query, userinfo or wildcard, a malformed port or bracketed IPv6 literal.
- **`cors(allowedOrigins:allowedMethods:allowedHeaders:)` (K2).** Strict CORS. No `Origin`: passes through. An origin not
  byte-for-byte on the list, or two `Origin` fields: `403`, code `origin_not_allowed`. `OPTIONS` from a listed origin: `204`
  with `Access-Control-Allow-Methods` (default `POST`) and `-Headers` (default `Authorization, Content-Type`), answered
  without calling the next handler, so authentication never sees it. Any other request from a listed origin: the handler's
  response, streaming included, with that one origin echoed in `Access-Control-Allow-Origin`; never a wildcard. With a
  non-empty list every response carries `Vary: Origin` (merged with the handler's own). Construction throws `CORSError`
  for `*`, `null`, a path, query, fragment, userinfo, an upper-case letter, whitespace, a malformed port, or an explicit
  default port (`:80` on `http`, `:443` on `https`: the last two are stricter than asked, because such an entry could never
  match), and for methods or headers that are not tokens. Place it before authentication and after `allowedHosts`.
- The brief named these `Middleware.allowedHosts` and `Middleware.cors`; `Middleware` is a function typealias and cannot
  hold static members, so they are free functions like `requestID`, `accessLog` and `rateLimit`.

### Verified (no change to the transport)
- **Spike S1 / K4: an idle handler is cancelled when the client leaves.** Seven real-socket tests (HTTP/1.1 keep-alive,
  `.closeAfterResponse`, a half-close, an idle streaming producer on both modes; HTTP/2 stream reset, connection close, an
  idle streaming producer on both) require the application's task to see `Task.isCancelled` within 1 s of the client
  leaving while it is suspended. All pass on the 0.4.1 transport (about 0.2 s each), so nothing was fixed. Removing
  `inFlight?.cancel()` from either `channelInactive` turns five of them red, and removing `streamTask?.cancel()` turns the two producer tests red.

### Notes
- Tests: 196 in the core (from 167), 268 in the transport (from 256).
- 48 hand mutants of the two files, each run alone against the core tests: 42 killed at first (one of them because it did
  not compile). The six survivors: a six-digit port allowed (`(1...5)` to `(1...6)`: equivalent, the value check rejects it
  anyway, and the guard exists to stop overflow); `0` as a port allowed, a space allowed, DEL allowed, and a port read from
  the tail of an IPv6 literal (four pieces of redundant code, each already rejected by a stricter check, removed); and a
  trailing empty label (`a.`) allowed, a missing case, now a test, and killed. Rerun after the changes: the port-leading-zero,
  port-65536 and trailing-label mutants are killed. The mutants: one Host required to at least one; request side and entry
  side not lower-cased; lower-casing stopping before `Z` or starting after `A`; an empty list accepted; status 421 to 400;
  the code changed; leading zero, 6 digits, 65536 and 0 in a port; the name check always true; space and DEL admitted;
  IPv6 with no colon; empty labels; two colons; text after a bracket; port digits unchecked; hex `g`; no underscore;
  `Vary` never added, `*` or `origin` not recognised in an existing `Vary`, a refusal, a preflight or an origin-less response
  not varied, `Vary` on an empty list; the preflight skipped (answered after the handler); two origins accepted; the origin
  compared case-insensitively; a wildcard echoed; the echo dropped; refusal `401`; upper case, a default port, a leading digit
  in the scheme or no `://` accepted; empty token, methods or headers accepted; methods and headers swapped; preflight `200`;
  the error order changed.
- `HTTPField.Name.host` is unavailable in HTTPTypes, so the kit keeps its own internal `Host` name.

## [0.4.1] - 2026-10-29

Found by the SwiftPushHub migration, which is the first consumer to rely on the transport's refusals. Nothing a caller
of 0.4.0 writes changes: `RefusalHooks` gains a defaulted third parameter, and the `SIGHUP` fix is internal.

### Added
- **`RefusalHooks.record` and `RefusalRecord`.** A request the transport refuses (a malformed target, a `Host` problem,
  an oversize body, a header over the limit, a timeout, a handler that threw) never reaches a handler or middleware, so
  an access log cannot see it. `record` is called once for each, before it is written, with the kind, the socket's peer,
  the client as a trusted proxy reported it, the HTTP version, and, when the request line had been read, the method and
  the target. A stranger wrote those, so they are made safe: the method is shown only if it is a token of at most 32
  characters; the target has every byte outside visible ASCII written as `%XX` (so it cannot end a log line or carry a
  control sequence) and is cut at 512 characters, marked `...`. Over HTTP/2 the request line is noted before anything
  else, so even a refusal for a head that is too large says what it was for. A refusal on a later request of a
  kept-alive connection does not borrow an earlier request's line. `observe` still works and is told once.

### Fixed
- **Overlapping `TLSReloadTrigger.hangup()` streams could hand `SIGHUP` back to its default.** Each stream saved what
  the one before it had installed, so the first to end could restore the default while another still listened, and the
  next `SIGHUP` would end the process. There is now one signal source for the whole process, shared and
  reference-counted: every signal reaches every open stream, and the disposition found when the first stream began
  (including `SIG_IGN`, for a process run under `nohup`) is put back only when the last one ends. Reported by the
  SwiftPushHub migration, from reading the code; reproduced by a test here.

### Notes
- A flake in the new `SIGHUP` tests, found by the gate and fixed before release: a stream ends a moment after its consumer
  is cancelled, and a test that reset `SIGHUP` to its default while an earlier stream was still registered would then
  signal a process whose source had not been reinstalled, and the signal ended the test run. Each such test now waits
  until no hangup stream is open. Eight consecutive runs of the gate's own test checker pass.
- Tests: 167 in the core, 256 in the transport (from 241). 38 hand mutants, each run alone: 30 killed at first; the
  survivors were missing cases (a digit in a method; a trusted-proxy refusal over HTTP/2; escaping inside the HTTP/1.1
  handler, which NIO's parser never lets unsafe bytes reach, so it is proved by driving the handler directly) and two
  equivalent mutants (an early-exit counter, and an explicit `cancel()` before a dispatch source is released).

## [0.4.0] - 2026-10-29

The kit now covers everything the servers it replaces need (owner's decisions D2 and D4, 2026-10-29), so that none of
them keeps a second system. Nothing a caller of 0.3.0 writes changes: every addition is a new type, or a parameter
with a default. Before 1.0 this package signals a source break with the minor version, and several public enums
gained cases (`RouterError.invalidBodyLimit`), hence 0.4.0. The design is `project/plans/proposals/DesignProposal_0.4.0.md`.

### Added
- **Typed responses, redirects, cookies.** `Response.html/.text/.javascript/.css/.png` (charset, `nosniff`,
  optional `Cache-Control`); `Response.redirect(to:status:allowing:)`, which accepts a path-absolute reference or an
  origin named by the caller, matched whole (`https://a.example` does not admit `https://a.example.evil` or
  `https://a.example@evil`), and refuses a backslash, space or control character; `Cookie`, validated against
  RFC 6265 (`SameSite=None` needs `Secure`, `__Host-` and `__Secure-` enforced, `Max-Age` up to 400 days), written by
  `Response.setting(cookie:)` as one `Set-Cookie` each; `Request.cookies`, lenient and non-throwing.
- **Form bodies.** `Request.form()` for `application/x-www-form-urlencoded`, strict: a `+` is a space, `%XX` needs
  two hex digits, a raw space or control or non-ASCII byte, an empty segment or name, a decoded NUL and invalid UTF-8
  are refused; bounded fields and field length; duplicates kept.
- **`Request.httpVersion`** (`HTTPProtocolVersion`: 1.0, 1.1, 2) and **`Request.peerAddress`**.
- **Transport refusal hooks.** `HTTPServer(configuration:handler:refusals:)` with `RefusalHooks(respond:observe:)`
  and `TransportRefusal`: the server gives the transport's own refusals a body and headers, and counts them. The
  status, closing the connection and the transport's headers stay the transport's. (On `HTTPServer`, not on
  `ServiceConfiguration`: that type is `Equatable`, and a closure is not.)
- **Per-route limits.** `Router.add/get/post/...(_:maximumBodyBytes:middleware:_:)`; the router answers
  `maximumBodyBytes(for:target:)` from the head alone by the same rule that serves the request, and
  `HTTPServer(configuration:router:middleware:refusals:)` wires it to the transport, which asks after the head and
  before any body. A route may lower or raise the global bound (0 to 64 MiB; otherwise a registration error that
  names the pattern).
- **`ServiceConfiguration(connections:)`**: `.keepAlive` (default) or `.closeAfterResponse`.
- **Trusted proxies.** `NetworkBlock` (CIDR, strict Swift IPv4 and IPv6 parsers: no leading zeros, no zone ids, no
  signs; `/0` refused), `ServiceConfiguration(trustedProxies:forwarding:)` (forwarding with nobody trusted is a
  configuration error). `.xForwardedFor` reads from the right and believes the header only from a trusted peer.
  `.proxyProtocol` reads version 1 and 2, before TLS, at the very front of the pipeline: required from a trusted
  peer, refused from anyone else who begins with a header, and anyone else's bytes pass on untouched.
  `NetworkBlock.canonicalAddress` gives one text per address (IPv4-mapped IPv6 is its IPv4 self).
- **Streaming responses.** `Response.streaming(status:headers:produce:)`; the `ResponseWriter` a producer writes to
  returns when the connection has taken the bytes, so a slow reader slows its producer and nothing queues without
  bound. HTTP/1.1 chunks; HTTP/2 `DATA` frames paced by flow control. To an HTTP/1.0 client and in answer to `HEAD`
  the head is sent unframed and the connection closes; a status with no body (204, 304) is an ordinary response and
  the producer is not run. New `Limits`: `maximumStreamDuration` (1 h), `maximumStreamBytes` (1 GiB),
  `streamWriteTimeout` (30 s). A producer that throws, a limit, a peer that leaves or stops reading, and a shutdown's
  grace all end the stream (the HTTP/1.1 connection closes; the HTTP/2 stream is reset, with `INTERNAL_ERROR` for a
  failing producer and `CANCEL` for a limit, and the connection and its other streams are untouched) and cancel the
  producer. The limits cut a producer off whether or not it ever looks at cancellation. `StreamError` says why.
- **Streams in the access log.** A streaming response is logged when its stream ends, with the bytes streamed;
  `ResponseStream.observing` and `discard()` let a layer hear of every end, including a stream that is never run
  (a `HEAD`, a bodyless status, a status that cannot be sent, a client that left first).
- **Server-sent events.** `Response.eventStream` and `EventWriter.send(data:event:id:retry:)` / `sendComment`: data
  is split at every break (CR, LF, CR LF); a name, id or comment with a line break (or a NUL in a name or id) is
  refused before anything is written, so a value cannot start another field or event.

### Fixed
- The timer trigger's cancellation: cancelling before the next wait finishes the stream, cancelling during it throws
  `CancellationError`. The 0.3.0 test and doc comment said it always threw, and the test was flaky.

### Notes
- **A test that passed for the wrong reason, and the fix.** SwiftTLSKit adds its TLS handler at the front of the
  pipeline, so a PROXY handler added before it ended up behind it, and the first version of the "header before TLS"
  test passed because the test client's TLS (also at the front) encrypted the header. The handler is now added after
  TLS so that it is first, and the test clients write the header unencrypted.
- **Tests.** 167 in the core (from 104) and 241 in the transport (from 151).
- **Hand mutation.** Roughly 400 mutants over the eight items, each run alone; survivors were missing cases (added),
  redundant code (removed) or unobservable. Two drivers had defects found and fixed along the way: one left mutants in
  the tree (caught by a failing run, reversed by hand, and the results discarded), and one counted crashes as
  survivors.

## [0.3.0] - 2026-10-29

Request id, access log and a rate limiter in the core; reload triggers in the transport; and a fix for a latent
crash. Nothing a caller of 0.2.0 writes changes.

### Fixed
- **Nothing touches an event loop after it has stopped.** NIO printed "Cannot schedule tasks on an EventLoop that
  has already shut down" once per server shutdown and says it will become a forced crash. Found with
  `SWIFTNIO_STRICT=true` and a backtrace for each; three causes. `ServerQuiescingHelper`'s `deinit` completes a
  promise on a loop, and the helper was released when the shutdown task ended, after the loops had stopped (on
  shutdown, and on a failed bind). And a handler that finished after its connection and the loops were gone hopped
  back onto a stopped loop, in `ConnectionHandler` and in `StreamHandler`. The helper is released before the
  group stops, and a handler's task checks that its channel is still open (`ChannelLiveness`). Tests watch
  standard error for the message: shutdown, a failed bind, and a handler outliving shutdown over each version
  of HTTP.

### Added: request id, access log, rate limiter (`SwiftHTTPService`)
Design: `project/plans/proposals/DesignProposal_Middleware.md`. All are `Middleware` in the core, with time
injected so the tests are deterministic.
- `requestID(header:generate:)` and `RequestID`, `HTTPField.Name.requestID`. An id offered by the caller is
  untrusted (it ends up in logs): used only if 1 to 64 characters of `A-Z a-z 0-9 . _ -`, otherwise replaced by a
  generated one, whole, never cleaned (a cleaned id can collide with a real one). A handler cannot override it.
- `accessLog(now:requestIDHeader:sink:)` and `AccessLogEntry`. No query string, header or body is ever recorded.
  A handler that throws is logged as `500` and the error goes on; its text is never logged. `line` is `key=value`
  with every value quoted and escaped (anything not printable ASCII is `\xNN` or `\u{...}`), so a value cannot end
  its field or start a second line.
- `RateLimit`, `RateLimiter`, `rateLimit(_:key:)`, `RateLimitError`. GCRA in integer nanoseconds: no floating
  point, one integer per client. Validated, nothing clamped (requests 1 to 1,000,000; interval up to a day;
  burst 1 to 10,000; the bounds keep the arithmetic inside `Int`). The table is bounded (`maximumKeys`, default
  10,000): idle clients go first, then the least recently active, so a flood of keys cannot grow memory. `429`
  as a problem (`rate_limited`) with `Retry-After` in whole seconds, rounded up. By default the key is the peer's
  address; behind a proxy that is the proxy, so key on what it reports.
- 27 hand mutations of the three. 22 were caught at first; the survivors were one missing test (idle time must not
  build credit past the bucket), one redundant clamp on `Retry-After` (removed: rounding up already gives at least
  one second), and one equivalent mutant (purging a client whose time equals now, which eviction would remove
  anyway). The `Retry-After` floor stays pinned by a test.

### Added: reload triggers (`SwiftHTTPServiceNIO`)
Design: `project/plans/proposals/DesignProposal_ReloadTriggers.md`. SwiftTLSKit has the loop and deliberately no
sources of triggers.
- `TLSReloadTrigger.hangup()`: one element per `SIGHUP`. The signal's default action is replaced for as long as
  the stream lives; when it ends the disposition found is put back (a test reads it with `sigaction`).
- `TLSReloadTrigger.every(_:)`: one element per interval, validated (above zero, at most a day). Pull-based, so no
  task runs in the background; it ends with `CancellationError` when the consumer is cancelled.
- `HTTPServer.reloadTLS(onEach:mode:report:)` (a stream that cannot throw, and one that can): reloads once per
  trigger through the server's state at that moment, so it can start before `start()` and survives a restart; a
  trigger with nothing serving TLS reports nothing. `mode` has no default, as in SwiftTLSKit.
- The parameter is `AsyncStream<Void>`, not a generic `AsyncSequence`: the generic form either warns about
  isolated conformances or needs `next(isolation:)`, which is macOS 15, and this package supports 14.

### Tests
151 in the transport (from 137) and 104 in the core (from 76).

## [0.2.0] - 2026-10-28

HTTP/2 over TLS. Nothing a caller of 0.1.0 writes changes: `ServiceConfiguration` and `Limits` gain defaulted
parameters, and HTTP/2 is on by default over TLS (`protocols: .http1` turns it off).

### Added: HTTP/2 (`SwiftHTTPServiceNIO`)
Design: `project/plans/proposals/DesignProposal_HTTP2.md`, which reverses D1 of the first design ("not now") at the
owner's request, 2026-10-28.
- Over TLS the server offers `h2` and `http/1.1` in ALPN and the negotiated protocol picks the pipeline. Plaintext
  stays HTTP/1.1: no `h2c`, no `Upgrade`. `ServiceConfiguration.protocols` (`.http1`, `.http1AndHTTP2`, default
  both) narrows it; a protocol that was not offered is never selected, whatever the peer sends.
- `Limits.maximumConcurrentStreams` (1 to 1000, default 100, the RFC 9113 suggested minimum: a recommendation, not
  a measurement). Advertised in SETTINGS and enforced.
- One `StreamHandler` per stream, written on raw frames and not on `NIOHTTPTypesHTTP2`, whose codec has
  `preconditionFailure` paths a peer can reach. The version-independent rules (`RequestRules`, `ResponseRules`,
  `Refusal.response`) are shared with HTTP/1.1; its tests passed unchanged through the extraction.
- A TLS connection that never finishes its handshake is closed at the idle timeout (`HandshakeDeadline`), as the
  HTTP/1.1 pipeline's idle timer used to do before handlers were added after negotiation.
- Dependency: Apple's `swift-nio-http2` (`from: "1.46.0"`), transport target only.
- Tests: 137 in the transport, from 91. Over real TLS with an h2 client; 22 malformed and 8 refused requests
  table-driven from RFC 9113 section 8; the attacks by hand-built frames, with a control showing modest use of
  the same frames is served.
- 27 hand mutations of the HTTP/2 code. 23 were caught. Four survived and none now: three were redundant code,
  removed (a byte check on the target that the core's parser already makes, which was never seen red; the
  grace time given to the library's connection management, which the server's own deadline repeats), and one
  was a missing test (two identical `Content-Length` fields, which the library lets through and the handler
  refuses with 400).

### What `swift-nio-http2` defends and what this package does (measured, not assumed)
- **The library:** all 22 malformed-request cases (pseudo-headers, upper-case names, connection-specific fields,
  CR/LF/NUL, `Content-Length` that is not digits or disagrees with the body) as a stream error of
  `PROTOCOL_ERROR`; rapid reset, small CONTINUATION floods, PING, SETTINGS and empty-DATA floods, each with a
  `GOAWAY` of `ENHANCE_YOUR_CALM` (11); a huge CONTINUATION block with `PROTOCOL_ERROR` (1); a stream past the
  advertised bound; idle connections and the `GOAWAY` handshake of a graceful shutdown
  (`NIOHTTP2ServerConnectionManagementHandler`).
- **This package:** the header-list size (the library advertises `SETTINGS_MAX_HEADER_LIST_SIZE` and does not
  enforce it; counted as RFC 9113 section 6.5.2 does, name plus value plus 32), the header count, the body bound
  with a `NO_ERROR` reset sent only after the response has been written (queued behind it, the reset dropped the
  response's own data), the body timer, `Host` against `:authority`, `Expect`, repeated `Content-Length`, the
  core's target parse, client trailers (refused), and the fixed problem bodies.
- **Not applied to HTTP/2:** `headerReadTimeout`. A header block arrives in one frame sequence bounded by the
  library's CONTINUATION limit; a connection with no stream open is bounded by `idleTimeout`.


## [0.1.0] - 2026-10-28

First release: the core, the HTTP/1.1 transport and TLS through SwiftTLSKit.

### Added
- `Request` with strict target parsing, `QueryItem`, `RequestError`, and `Context` with typed keys.
- `Response` (`json`, `empty`, `notModified`, `problem`, `setting`, `retrying`) and `Problem` (RFC 9457).
- `Handler`, `Middleware` and `wrap(_:with:)`.
- 33 tests. Hand mutations of the parser, the encoder settings and the problem content type were caught; the
  one that survived (a redundant `//` check) was removed.
- `Router` (`add`, `get`/`post`/`put`/`patch`/`delete`, `handler`), `RouterError`; replaceable `notFound` and
  `methodNotAllowed`; `Allow` on a 405. 17 tests worked out by hand, including that no registration order
  changes which handler a request reaches; 10 router mutations caught.
- `EntityTag` and `Conditional` (`ifNoneMatch(_:matches:)`, `respond(to:etag:produce:)`): 28 table cases from
  RFC 9110; 9 mutations caught, 2 only after two cases were added (`Wx"abc"` and a non-ASCII tag in a list).
- `Router.addHealth(at:)`.
- `LICENSE`: proprietary, all rights reserved, for now.

### Transport (`SwiftHTTPServiceNIO`) and configuration
- `ServiceConfiguration`, `Limits`, `TLSFiles`, `ConfigurationError` in the core: a throwing initialiser that
  checks every range and clamps nothing; an error names the field and the kind of fault and never the value;
  the host defaults to `127.0.0.1`. 8 tests, 24 refusals, 15 edges; 18 range mutations, all caught.
- `HTTPServer` (`start() -> BoundAddress`, `reloadTLS(_:)`, `shutdown()`), `BoundAddress`, `HTTPServerError`:
  HTTP/1.1 over TCP, and TLS 1.2 or newer (HTTP/1.1 ALPN only). TLS identity loading, judging and reload are
  the owner's **SwiftTLSKit** (`ServerIdentity`, `ReloadableServerTLS`, `ServerTLSOptions`): every way an
  identity can be unfit is a typed `ServerIdentityError` inside `HTTPServerError.tlsIdentity`, naming the path
  and never the contents; a renewed certificate is taken by `reloadTLS()` with no restart. `BindExposure`
  decides what counts as exposed: plaintext on a host that is not loopback is
  `HTTPServerError.exposedPlaintext(host:)`. A start that fails for either reason can be tried again.
- Enforced: the request line and headers counted as the bytes arrive (`431`), a header-field count (`431`), a
  body limit checked against `Content-Length` before any body is read and against a chunked body as it grows
  (`413`), a header deadline from a request's first byte (`408`; dripping bytes does not extend it), a body
  deadline (`408`), a keep-alive idle timeout (close, nothing written), and a connection cap (closed at once,
  nothing written).
- Refused as ambiguous (`400`): a `Content-Length` with a `Transfer-Encoding`; a duplicate, signed,
  hexadecimal, listed or non-numeric `Content-Length`; a `Transfer-Encoding` other than exactly `chunked`; a
  missing or duplicate `Host` on HTTP/1.1; CR, LF or NUL in a header value; and (through NIO's parser) folded
  lines, bare line feeds and malformed names. A refusal is a fixed `application/problem+json` body that is
  byte for byte what the core's `Response.problem` produces for the same status and code, and never contains
  anything the peer sent or any error text. A handler that throws is a fixed `500` and the connection closes.
- The transport owns `Content-Length`, `Connection`, `Date` and `Transfer-Encoding`: a handler cannot set
  them. `HEAD` carries the headers a `GET` would and no body; `204` and `304` carry no length. `Expect:
  100-continue` is answered with `100` within the body limit and refused with `413` over it; any other
  expectation is `417`.
- Pipelining is not supported: the first request is answered with `Connection: close` and the second is never
  run. A handler that never returns is not bounded by the transport.
- Graceful shutdown is NIOExtras' `ServerQuiescingHelper`: the listening socket closes, every open connection
  is told to quiesce, an idle one closes at once, a busy one finishes its request and closes, and after
  `shutdownGrace` whatever is left is closed. Idempotent, and safe from several tasks.
- 91 transport tests: byte-level pipeline tests on `NIOAsyncTestingChannel`, the connection handler tested
  directly with no parser in front (its own rules must not depend on NIO's), and real loopback sockets for
  the lifecycle, the cap, real timers, TLS, reload, and the typed identity errors. Certificates are generated
  when the tests run (SwiftTLSKitTestSupport), so no key is checked in. Ten consecutive runs of the whole
  suite passed.

### Decisions about `swift-nio-extras` (evaluated before building)
- **Adopted:** `NIOExtras.ServerQuiescingHelper`, in place of a hand-written drain and wait. It also closes a
  connection that arrives during shutdown, which made two flags of ours redundant (removed).
- **Not adopted, `NIOHTTPTypesHTTP1`:** `HTTP1ToHTTPServerCodec` rewrites an absolute-form target such as
  `http://other.example/v1/me` into the path `/v1/me`, so the core's strict origin-form rule would never see
  the original, and it moves the first `Host` into `authority`, so a count of `Host` fields is off by one. Both
  are pinned by `ExtrasBridgeAssumptionTests`; if a later release changes either, revisit.
- **Not adopted, `NIOCertificateReloading`:** it links `swift-service-lifecycle`, which is the Swift Server
  Workgroup's and not Apple's. The owner's SwiftTLSKit does the reload instead (and also the identity checks
  that package does not have).
- **Removed after SwiftTLSKit:** my own `TLSIdentity` (PEM loading, BoringSSL context building, the
  unreadable/rejected errors, minimum version and ALPN), the committed test certificate and key, and the
  direct `swift-nio-ssl` dependency (it still arrives through SwiftTLSKit).
- **SwiftTLSKit is a URL dependency**, `.upToNextMinor(from: "0.2.1")`, in place of the sibling path
  `../SwiftTLSKit`: the package now resolves on its own. SwiftTLSKit needed no new tag; 0.2.1 is the pin.
- Adding `swift-nio-extras` resolves `swift-service-lifecycle` into the lockfile even though nothing links it.

[Unreleased]: https://github.com/jpurnell/SwiftHTTPService/compare/v1.0.0-beta.2...HEAD
[1.0.0-beta.2]: https://github.com/jpurnell/SwiftHTTPService/compare/v1.0.0-beta.1...v1.0.0-beta.2
[1.0.0-beta.1]: https://github.com/jpurnell/SwiftHTTPService/compare/v0.8.1...v1.0.0-beta.1
[0.8.1]: https://github.com/jpurnell/SwiftHTTPService/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/jpurnell/SwiftHTTPService/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/jpurnell/SwiftHTTPService/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/jpurnell/SwiftHTTPService/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/jpurnell/SwiftHTTPService/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/jpurnell/SwiftHTTPService/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/jpurnell/SwiftHTTPService/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/jpurnell/SwiftHTTPService/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/jpurnell/SwiftHTTPService/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/jpurnell/SwiftHTTPService/releases/tag/v0.1.0
