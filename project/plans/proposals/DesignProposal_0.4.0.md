# Design Proposal: 0.4.0, the kit that covers every server

**Status:** Proposed 2026-10-29. The owner decided (D2, D4) that the kit covers all the servers' needs so that no
second system is maintained, and asked for the consumer's findings to land before migration. Decisions inside
this document are mine, each with its reason, and open to reversal; the owner has asked for little intervention.

0.4.0, not 0.3.1: every item adds public API, and before 1.0 this package signals a source break with the minor
version. Each item below is source-compatible for a caller of 0.3.0 (new parameters have defaults), but the
signal is still the minor.

## Build order and why
Cheap and independent first, so each can ship alone on its branch and merge; the transport items that touch the
same handlers are serialised after them.

| # | Item | Where | Needed by |
|---|---|---|---|
| 1 | Responses: `html`, `text`, `javascript`, `css`, `png`, `redirect`; typed `Cookie` | core | FleetWatch |
| 2 | Form bodies: strict `application/x-www-form-urlencoded` | core | FleetWatch `/authorize` |
| 3 | `Request.httpVersion` | core + transport | consumer finding |
| 4 | Transport refusal hook: a responder and an observer | transport | consumer finding |
| 5 | Per-route limits: a body bound and middleware per route | core + transport | Hub 64 KiB, login route |
| 6 | Close-after-response mode | transport | FleetWatch, Hub clients |
| 7 | Trusted proxy: `X-Forwarded-For` and the PROXY protocol | core + transport | consumer finding |
| 8 | Streaming responses | core + transport | SwiftMCPServer (D2) |

## 1. Response helpers and cookies
- `Response.html(_:)`, `.text(_:)`, `.javascript(_:)`, `.css(_:)`, `.png(_:)`: correct `Content-Type` with `charset`
  where text, and `X-Content-Type-Options: nosniff` on all of them. An optional `cacheControl`.
- `Response.redirect(to:status:)`: the target must be a path-absolute reference (`/x`, no `//`, no scheme, no
  backslash, no control character) unless it is on an allow-list given by the caller, so a redirect built from
  input is never an open redirect. Statuses 301, 302, 303, 307, 308 only; `Location` is set.
- `Cookie`: name and value validated against RFC 6265 `token` and `cookie-octet`; `Secure`, `HttpOnly` and
  `SameSite` are required choices with safe defaults (`Secure`, `HttpOnly`, `Lax`); `Path`, `Max-Age`; the
  `__Host-` prefix forces `Secure`, `Path=/` and no `Domain`. `Response.setting(cookie:)` appends a
  `Set-Cookie` (never replaces another). `Request.cookies` parses the `Cookie` header, ignoring a malformed pair
  and never throwing.

## 2. Form bodies
- `Request.form()` parses `application/x-www-form-urlencoded` strictly: `+` is a space, `%XX` must be two hex
  digits, invalid UTF-8 and a NUL are refused, a bound on the number of fields (default 100) and on a field's
  length, and duplicate names are kept in order (the handler decides). Any other content type is an error, not
  an empty form. `multipart` is out of scope.

## 3. Request.httpVersion
- `HTTPProtocolVersion` (`.http1_1`, `.http2`; HTTP/1.0 is served as `.http1_0` if the transport serves it).
  The transport sets it; the `Request` initialiser defaults to `.http1_1`, so existing callers and tests compile.

## 4. Transport refusal hook
- `HTTPServer.init(configuration:handler:refusals:)` takes `RefusalHooks`: `respond`, a `@Sendable (TransportRefusal)
  -> Response?` that may replace the body and headers of the transport's own refusals (400, 408, 413, 417, 431,
  500), and `observe`, called once for each. (Not on `ServiceConfiguration`, as first proposed: that type is
  `Equatable`, and a closure is not.) The status, the closing of the connection and the headers the transport owns
  stay the transport's, whatever the hook returns; returning nil keeps the fixed default. `TransportRefusal` is a
  public enum of the kinds, with no peer-supplied value in it. Neither closure may throw or block.

## 5. Per-route limits
- The body bound is known only after the route is, but the transport checks it before it reads a body. So
  `Router.add(_:_:maximumBodyBytes:middleware:_:)` (and `get`, `post`, ...) take a per-route bound and per-route
  middleware, both defaulted, and `Router.maximumBodyBytes(for:target:)` answers "what is the bound for this method
  and target?" from the head alone, by the same rule that serves the request (the shared `winning` function), so it
  can never name a different route. `HTTPServer(configuration:router:middleware:refusals:)` wires the router to the
  transport; the transport asks after the head, before any body, and the answer replaces the global bound, lower or
  higher. A bound outside 0 to 64 MiB is a registration error naming the pattern, never clamped, and a refused
  registration changes nothing. A path with no route, or a route with no override, takes the global bound.
- Per-route middleware runs inside the layers wrapped around the whole router, the first listed outermost, so a
  login route takes a tighter `rateLimit` than the rest.

## 6. Close-after-response mode
- `ServiceConfiguration.connections: .keepAlive | .closeAfterResponse`. For clients that cannot reuse a
  connection. HTTP/2 is unaffected (a stream is one request already).

## 7. Trusted proxy
- A security decision before a feature, and one rule: **forwarded information is believed only from a trusted peer.**
  `ServiceConfiguration(trustedProxies:forwarding:)`: a list of CIDR blocks (`NetworkBlock`, parsed by strict Swift
  parsers: no leading zeros, no zone ids, no signs; the block of every address, `/0`, is refused) and a mode,
  `.none` (default), `.xForwardedFor` or `.proxyProtocol`. Forwarding with nobody trusted is a configuration error.
- `Request.remoteAddress` is the client as the handler should see it (rate limits and the access log key on it);
  `Request.peerAddress` is always the socket's.
- `.xForwardedFor`: from a trusted peer, the header is read **from the right**: the first address that is not itself
  a trusted proxy is the client (a client controls what it writes at the left; a proxy controls what it appends).
  Anything that is not an address, a port on an address, an empty entry, or more than 20 entries means the peer is
  used, never a guess.
- `.proxyProtocol`: version 1 (text) and version 2 (binary), parsed by a pure function that is strict (a doubled
  space, a leading zero, a wrong family, an unknown version, a length over 1024 are all refused). **A trusted peer
  must send the header** (not a header, a malformed one, or one unfinished at the header timeout closes the
  connection with nothing written). **Any other peer must not**: one that begins with a header is pretending to be
  a proxy and is closed; one that begins with anything else is served as itself. The handler is at the very front
  of the pipeline, ahead of TLS, because the header precedes the handshake (SwiftTLSKit adds its handler at the
  front, so the PROXY handler is added after it). An earlier version of the tests passed with the header decrypted
  by TLS first, which is not the protocol; the test clients now write it unencrypted too.

## 8. Streaming responses
- `Response.streaming(status:headers:body:)` where `body` is `@Sendable (inout ResponseWriter) async throws -> Void`.
  The status and headers are fixed when the stream starts; `write(_:)` suspends under backpressure (the channel's
  writability), so a slow reader slows the producer and memory stays bounded.
- Bounds, all in `Limits`, validated, nothing clamped: `maximumStreamDuration`, `maximumStreamBytes`,
  `streamWriteTimeout` (a peer that stops reading is cut off). HTTP/1.1: chunked. HTTP/2: DATA frames with flow
  control. The task is cancelled when the peer goes, and at the end of a shutdown's grace. HEAD sends the head only.
- Middleware sees the status and headers at start; `accessLog` records the bytes streamed when it ends.
- `Content-Length` is not set; `Conditional` does not apply.

## Out of scope
Multipart, WebSockets, a template engine, sessions. Authentication stays the server's, as middleware.
