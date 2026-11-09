# Design Proposal: 0.6.0, the busy refusal, the other wire differences, and the public API audit

**Status:** Built 2026-10-30 at the owner's request. Order: the regression SwiftMoE found (owner priority), then the other
differences its replay found, then the audit that was waiting for 1.0.

## 1. The regression: a connection past the cap was closed with no answer

**Found by** the SwiftMoE v0.2.0 migration. The hand-rolled server it replaced answered `503 Service Unavailable` with
`Retry-After` past its connection cap (`refuseBusy`, bounded by a second semaphore, `refusalSlots`); the kit closed the
connection with nothing written (`ConnectionRegistry.admit` failing the channel initializer). Reproduced first, with a red
real-socket test (`LifecycleTests.connectionCap`, which had pinned the silent close as intended).

### 1.1 What is done, in plaintext (HTTP/1.1)
A connection past `Limits.maximumConnections` is given `BusyRefusalHandler` and no HTTP pipeline at all:
- It is **written to as soon as it opens, and never read.** No parser, no `HeadGuard`, no handler task, no body buffer. The
  answer is `503`, `application/problem+json`, the fixed body (`{"code":"service_unavailable","status":503,"title":"Service
  Unavailable","type":"about:blank"}`), `Retry-After`, `Connection: close`, `Content-Length`, `Date`.
- After the write, the **output side is shut down and the input is drained and dropped**, until the peer leaves or the deadline.
  Writing an answer and then closing with the peer's request still unread sends a TCP reset, and a reset can destroy a response the
  client has not yet read; draining first is the standard cure (the old server's `Unread` handling was for the same reason).
- **Bounded two ways.** `ConnectionRegistry.defaultRefusalSlots` (32) connections may be being refused at once; one past that is
  closed with nothing written, as before. And each refusal lives at most `BusyRefusalHandler.deadline` (2 s) whether or not the
  peer reads. The slot is released when the channel closes, so a peer that reads and leaves frees it at once. Worst case a flood
  at the cap costs 32 descriptors and 32 timers for 2 s at a time, and a reply of about 300 bytes each.
- `Limits.busyRetryAfter` (a `Duration`, default 1 s, above zero and at most an hour, validated like its siblings) sets
  `Retry-After`, **rounded up** to whole seconds (RFC 9110 10.2.3 allows only integers, and rounding down tells a client to come back
  too soon). The refusal count (32) and deadline (2 s) are internal constants, not parameters: they are the bound on a defence, and a
  knob that can lift a defence is how it gets lifted by mistake. *Considered: `Limits.maximumRefusals`.* Left out; adding it later
  is source-compatible, and removing it is not.

### 1.2 Hooks
A new `TransportRefusal.busy` (code `service_unavailable`, status 503). `RefusalHooks.respond` shapes the body and headers,
`observe` counts it, `record` sees it, exactly as for the other transport refusals. Two things are the transport's, not the hook's:
the status (as always) and **`Retry-After`**, which is replaced after the hook runs, because the number is a statement about the
server's capacity. The record has the peer, `remoteAddress` equal to the peer (no `X-Forwarded-For` or PROXY header has been read
and none will be), and **no method, target or version**.

### 1.3 TLS and HTTP/2: what is possible, and the decision
Over TLS a connection past the cap can only be given an HTTP answer **after the handshake**, and an HTTP/2 connection
(negotiated by ALPN during it) can only be given one as HTTP/2 frames: a `503` HEADERS frame on a stream the client opens, after
SETTINGS. There is no way to say "busy" to an `h2` client before the handshake, and a plaintext `503` written to a TLS socket is
a handshake failure to the client. Two options:
- (A) close before the handshake (the behaviour before 0.6.0);
- (B) handshake, then answer: HTTP/1.1 ALPN gets the same bytes; `h2` needs an h2 mini-server (SETTINGS, wait for a stream,
  one HEADERS + DATA, GOAWAY) or a negotiated-down `http/1.1`.

**Evidence.** In-process, debug build, both endpoints in the same process, 300 sequential connections to a loopback server with test
certificates: a plaintext refusal costs **0.92 ms CPU** per connection (7.8 ms wall); a TLS connection that completes the handshake
and gets a response costs **6.9 ms CPU** (13.4 ms wall): **about 7.5 times** the CPU. The handshake is the work the cap exists to
refuse, an attacker pays for a TCP connect and a ClientHello and the server pays for key agreement and a signature, and (B) would
spend it on exactly the connections it has no room for. (B) also needs new HTTP/2 code in the one place that must not be fragile.
**Decision: (A). Over TLS, a connection past the cap is closed before the handshake; nothing is written and no hook is called.** *(Reversed in 0.7.0 at the owner's request: option (B), with 8 refusal slots; see CHANGELOG.)*
Pinned by `BusyRefusalTests.tlsIsClosedBeforeTheHandshake` (HTTP/1.1 and `h2` offers; `handshakeCompleted` false). Operators
who want clients told over TLS terminate TLS in a proxy in front (it can answer 503 itself) or size the cap above the load. The
"HTTP/2" half of the owner's question: the kit has no `h2c`, so every HTTP/2 connection is a TLS connection and falls under (A);
within an admitted HTTP/2 connection, streams past `maximumConcurrentStreams` are refused with `REFUSED_STREAM` by the library, which
is the HTTP/2-native "busy" and needs nothing here.

### 1.4 Adversarial review
- *Why not read the request first and answer it?* A request read is a parser and a buffer per refused connection: the cost the
  cap exists to avoid. The old server read the head with a deadline; here nothing is read, at the cost of answering a client that
  has not yet sent its request (harmless: the answer is for the connection, not for a request).
- *Does answering before reading break a client mid-request?* The drain-then-close sequence avoids the reset. A client that is
  still writing a large body gets the answer when it next reads; tested with a request sent into a refusal (`requestIsIgnored`).
- *Can the refusal be used to exhaust the server?* 32 slots, 2 s each, then silent drops; both bounds tested
  (`bounded`, `slotsAreReleased`, `admission`), and a mutation that removes either is killed (CHANGELOG).
- *PROXY protocol:* a load balancer sends its header first; the refusal does not read it, so the `503` goes back to the balancer
  and not the client. Documented; the alternative is reading a header from a connection we are refusing.
- *The new `TransportRefusal` cases break an exhaustive `switch`.* SwiftMoE has one without a `default`. Unavoidable if the kind is a
  `TransportRefusal` (the owner asked for that); recorded below and in the CHANGELOG, and the type's documentation now says to
  end a `switch` with `default`.

## 2. The other differences SwiftMoE found

| # | Finding | Cause, determined | Decision |
|---|---|---|---|
| (a1) | A request that stops sending before its `Content-Length` bytes arrive "is closed with no response" | **Not reproduced on a live peer.** The body timer (`bodyReadTimeout`, armed when the head ends) fires and writes `408`. Pinned by `stalledBody`. What is closed silently is a peer that has already gone (FIN or reset): there is nobody to answer, and a half-closed peer's FIN is read as the end of the connection. | No change. Documented: a 408 is written if and only if the peer is still there when the timer fires. |
| (a2) | A client that connects and sends nothing is closed with no `408` | **The idle timer** (`idleTimeout`, 60 s by default) fires, not the header timer, which starts at a request's first byte. The kit closed it silently. The old server answered `408`. RFC 9110 15.5.9 allows either; for a connection that has never sent a byte the request is *late*, not *idle*. | **Fixed.** A new connection (no byte received) that reaches `idleTimeout` is answered `408` (fixed body, hooks as for any `.requestTimeout`) and closed. A keep-alive connection that goes quiet *after* a request is still closed silently: a `408` there can cross a request the client has just sent. HTTP/2 is unchanged (the library's `GOAWAY`). Over TLS a peer that never completes the handshake is closed silently (nothing can be written). |
| (b) | `HTTP/2.0` in an HTTP/1.1 request line is `400`; RFC says `505` | NIO's parser rejects any version but 1.0/1.1 with `invalidVersion`, and its error does not carry the line. | **Fixed, cheaply:** `HeadGuard` sees the raw bytes and reads the first line's last token. ` HTTP/d.d` with a major digit other than 1 is `505` (new `TransportRefusal.versionNotSupported`, code `http_version_not_supported`), before the parser sees it. `HTTP/1.2`, `HTTP/2`, `http/2.0`, `HTTP/abc` stay `400` (not a major version we refuse; the parser's call). Works across packet splits and on a second request on the same connection. |
| (c) | `HTTP/1.1` with no `Host` is `400` | Correct, RFC 9112 3.2. | Left. |
| (d) | A body declared over the bound is `413` before the credential check | Correct for a transport: it cannot read a credential from a body it refuses, and reading it to find one is what the bound forbids. | Left. Documented in the CHANGELOG; pinned by `contentTooLarge` (the handler never runs). |
| (e) | The `413` line reads "Payload Too Large" | NIO's status table has the pre-RFC 9110 phrase. | **Fixed:** `ResponseRules.wireStatus` gives 413 `Content Too Large`, 416 `Range Not Satisfiable`, 422 `Unprocessable Content` (the three RFC 9110 renamed), everything else NIO's. Applies to the handler's own statuses as well as the refusals'. |

## 3. The public API audit

Method: read every public declaration of the types the owner listed; checked DocC coverage mechanically (every `public` declaration
and every public enum case has a doc comment: **no gaps**); read how the four consumers use the kit
(SwiftPushHub, FleetWatch, ijs-dashboard-server, SwiftMoE) so a rename is judged by what it costs them.

| Symbol | Finding | Decision | Compat |
|---|---|---|---|
| `ServiceConfiguration.connections` / init label `connections:` | Misleads: beside `Limits.maximumConnections` it reads as a count. It is a reuse mode | Renamed `connectionReuse` (type already `ConnectionReuse`). Old property and init label kept as `@available(*, deprecated, renamed:)` shims **for exactly one release** (removed in 0.7.0 or 1.0.0, whichever comes first). The old init requires `connections:` so a call without it is not ambiguous | **BREAKING rename, shimmed.** SwiftPushHub, FleetWatch, SwiftMoE use `connections:` and compile with a deprecation warning |
| `TransportRefusal` | Lacked `Hashable` (a counter keyed by kind is the first thing a hook does); growth breaks exhaustive switches | `Hashable` added; DocC says the set grows and a `switch` should have a `default`. New cases `.busy`, `.versionNotSupported` | Source-compatible except for an exhaustive `switch` (see 1.4): **SwiftMoE's `ChatService.refusal(for:)` needs `case .busy` and `case .versionNotSupported`, or a `default`** |
| `RefusalRecord` | `init` was internal, so a server's own `record` function cannot be unit-tested without a socket (SwiftPushHub's `recordRefusal(kind:peer:method:target:...)` is that workaround); lacked `Hashable` | `init` public, documented that nothing is checked there; `Hashable` | Source-compatible |
| `RefusalHooks` | `respond`, `observe`, `record` are `let` closures with a defaulted init: fine. `observe` is subsumed by `record` but both are in use (SwiftPushHub passes `respond`, `observe` and `record`; FleetWatch `respond` and `record`) | Left | None |
| `Request.init` | `throws` (untyped) while every sibling initialiser uses typed throws, although only `RequestError` can be thrown | `throws(RequestError)` | Source-compatible (callers' `try` and `catch` unchanged) |
| `QueryItem`, `HTTPProtocolVersion`, `EntityTag`, `RateLimit`, `StreamError`, `Cookie.SameSite`, `ServiceConfiguration.Forwarding`, `.ConnectionReuse`, `.Protocols`, `BoundAddress` | `Equatable` but not `Hashable`, though all are plain values | `Hashable` added (a conformance cannot be removed after 1.0, which is why it is decided now: each is a value type whose equality is its fields) | Source-compatible |
| `Form`, `FormField`, `CookiePair`, `Problem`, `AccessLogEntry`, `Response`, `Request`, `Context` | Output or carrier types; `Response`/`Request` hold closures or `Context` | Left. `Hashable` on `Response` (body bytes) and `Request` would invite use as cache keys; the small output types can gain it after 1.0 without a break | None |
| `Limits` field names | `maximum*` (sizes, counts, a lifetime), `…Timeout` (waits), `shutdownGrace`, `busyRetryAfter`. Checked for `max*` and `…Deadline`: none present; `maximumStreamDuration` is a lifetime ceiling and `streamWriteTimeout` a per-write wait, which is the distinction the names draw | Left | None |
| `Limits.busyRetryAfter` | New | `Duration`, validated 0 < d <= 1 h, `busyRetryAfterSeconds` is `package` (the transport needs it, applications do not) | Additive |
| `Cookie.maxAge`, `Response.retrying(after:)`, `EventWriter.send(retry:)` | Integer seconds / milliseconds where `Limits` and `RateLimit` take `Duration` | Left: each is a wire value (`Max-Age`, `Retry-After`, SSE `retry:`) and its unit is documented on the symbol; a `Duration` overload can be added after 1.0 | None |
| `Request.firstQueryValue(named:)`, `Request.cookie(named:)`, `Form.first(_:)`, `Form.all(_:)` | Lookup labels differ (`named:` vs none) | Left: a renamed or doubled accessor is churn for a spelling difference; the unlabeled form reads as a method on the thing that holds the fields | None |
| `NetworkBlock.isAddress`, `.canonicalAddress`, `ResponseStream.produce/discard`, `ResponseWriter.init`, `Router.maximumBodyBytes(for:target:)` | Look internal | **Kept public.** The README promises "a consumer that brings its own transport links no NIO"; a transport needs exactly these. Documented as transport-author API | None |
| `HTTPServerError.exposedPlaintext(host:)`, `RouterError` cases with patterns | Carry a value, where `ConfigurationError` deliberately does not | Left: the host and the route pattern are the developer's own constants, named so the message can say what to change; neither is peer input, and a secret would have been rejected earlier as a `ConfigurationError`. Recorded so it is a decision and not an oversight | None |
| `TLSReloadTrigger`, `HTTPServer.reloadTLS(onEach:mode:report:)` | `mode` and `report` have no defaults, `reloadTLS(_:)` does | Left: a default mode would pick between "always" and "if changed", which differs by trigger, and a defaulted `report` is a silent failed renewal | None |
| `ResponseStream.observing(_:)` | Closure takes an unlabeled `(Int, (any Error)?)` | Left: used only by `accessLog`; relabeling is breaking and the type is rarely touched | None |
| `requestID`, `accessLog`, `rateLimit`, `allowedHosts`, `cors` | Parameter names for a header (`header:` vs `requestIDHeader:`) differ | Left: `accessLog` reads a *response* header of a layer inside it, `requestID` names the header it sets; the names say that | None |
| Public DocC | Scanned mechanically | No gaps | None |

**Counts.** Decided: 8 changes (1 rename with shim, 1 typed-throws, 1 initialiser made public, 3 conformance sets, 2 new
cases with the kind's `Hashable`); considered and left: 9 rows. Nothing was removed.

## 4. Verification
See the CHANGELOG for the mutation list and the consumer build results (recorded there so they are not copied twice).
