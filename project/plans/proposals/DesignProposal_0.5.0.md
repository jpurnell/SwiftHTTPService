# Design Proposal: 0.5.0, idle cancellation proved, `allowedHosts`, `cors`

**Status:** Built 2026-10-30 at the owner's request for the SwiftMoE migration
(`DesignProposal_HTTPServerOnSwiftHTTPService.md` in that repository, sections 3, 4.2, 4.3, 9, 10). Order: the spike first,
because if it had been red the other two would have waited behind a transport fix.

## 1. Spike S1 / K4: does an idle handler hear the client leave?
**Question.** The transport cancels `inFlight` and `streamTask` in `channelInactive`, but nobody had shown that the channel
goes inactive when the peer leaves while the application is only suspended (not reading, not writing). Suspects: NIO
half-closure handling, auto-read, and HTTP/2, where leaving a stream is `RST_STREAM` and leaving the connection is
`GOAWAY`/FIN.

**Method.** Real sockets (`RawClient`, `H2Client`). The handler sleeps in 10 ms steps checking `Task.isCancelled` (it gives up
on its own after 8 s, so a test cannot hang), the client sends a full request, waits 200 ms, leaves, and the test requires the
cancellation inside 1 s. Cases: HTTP/1.1 keep-alive; `.closeAfterResponse`; a client that only half-closes (FIN, still
reading); an idle streaming producer on both connection modes; HTTP/2 stream reset; HTTP/2 connection close; an idle
streaming producer on HTTP/2 (reset, and connection close).

**Result.** All green with no transport change. The tests can fail: with `inFlight?.cancel()` removed from either
`channelInactive`, five of the seven go red; with `streamTask?.cancel()` removed, the two producer tests do.

## 2. K1 `allowedHosts(_:) throws(AllowedHostsError) -> Middleware`
- `421` problem, code `misdirected_request`, title given explicitly (HTTPTypes has no phrase for 421).
- Whole-value, exact comparison, ASCII case folded (a Unicode `lowercased()` would make the Kelvin sign a `k`). `host:port`
  admits that port only; a bare `host` admits a `Host` with no port only (the decision: "exact" taken literally, so the
  caller states both spellings if both are used).
- Zero or two `Host` fields: refused. Nothing is normalised (trailing dot, space, userinfo).
- Refused at construction, by position: empty list; empty entry; any byte outside visible ASCII (so whitespace, control
  characters, non-ASCII); a scheme, path, query, fragment, userinfo, wildcard or list; a port that is not 1 to 65535 written
  plainly; a malformed bracketed IPv6 literal; empty labels.
- Read from `Host`, because the transport already copies HTTP/2 `:authority` into it.

## 3. K2 `cors(allowedOrigins:allowedMethods:allowedHeaders:) throws(CORSError) -> Middleware`
The rule is SwiftMoE's `decide()`, made route-agnostic:
1. No `Origin`: pass through. (`Vary: Origin` is still added when the list is non-empty: the cache rule is about every response.)
2. `Origin` not byte-for-byte on the list, or two `Origin` fields: `403` problem `origin_not_allowed`.
3. `OPTIONS` from a listed origin: `204` with `Allow-Methods` and `Allow-Headers`, answered without calling `next`, for any path.
4. Otherwise: `next`, then `Access-Control-Allow-Origin: <that origin>` on whatever came back, a streaming response included.
- `Vary: Origin` is appended beside the handler's own `Vary`, and not repeated if it already names `Origin` or `*`.
- Entries: `scheme://host[:port]`, all lower case, no path/query/fragment/userinfo, `*` and `null` refused; **also refused**
  (beyond the brief, because each is an entry that could never match and would fail silently): an upper-case letter in the
  host and an explicit default port (`:80` for `http`, `:443` for `https`, which a browser leaves out).
- An empty list is allowed and means "no origin is", not "CORS off": a request naming an origin is `403`, as SwiftMoE does.
- Methods and headers are HTTP tokens, at least one each, so a value cannot carry a line break into a header.
- **Order:** after `allowedHosts` and logging, before authentication. Tested with a stand-in auth layer both ways.
- An error the handler throws has no response to carry the headers; the transport's `500` has none (as with `requestID`).

## 4. Adversarial review
- *Why free functions, not `Middleware.allowedHosts`?* `Middleware` is a typealias of a function type; it cannot be extended.
  The house style (`requestID`, `accessLog`, `rateLimit`) is the same.
- *Should the preflight check `Access-Control-Request-Method`?* No: SwiftMoE does not, and a preflight that over-answers is
  harmless because the real request is checked again. The listed methods are what the browser will then enforce.
- *Why does an Origin-less request still get `Vary`?* A shared cache that stored the origin-less answer would otherwise serve it
  to a request that has an origin.
