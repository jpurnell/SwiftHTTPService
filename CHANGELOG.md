# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project will follow
[Semantic Versioning](https://semver.org/) from 0.1.0.

## [Unreleased]

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

[Unreleased]: https://github.com/jpurnell/SwiftHTTPService/compare/v0.4.1...HEAD
[0.4.1]: https://github.com/jpurnell/SwiftHTTPService/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/jpurnell/SwiftHTTPService/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/jpurnell/SwiftHTTPService/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/jpurnell/SwiftHTTPService/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/jpurnell/SwiftHTTPService/releases/tag/v0.1.0
