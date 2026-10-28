# Consumer Requirements: what every hand-rolled server needs from the kit

**Status:** survey, 2026-10-28, for the owner. Read-only: no consumer was changed, run or reached over the network.
**Why:** the owner decided on 2026-10-28 to build every missing feature into the kit first and then migrate every
hand-rolled server, because migrating them is the only real test the kit will get. That order only works if the
feature list comes from what the consumers actually do. This document is that list. It replaces §3 of
`MigrationPlan_HandRolledServers.md`, which marked several needs "not read" and got some of them wrong (§6).

**Kit baseline:** `main` at `492109a` (v0.2.0 plus the stopped-loops fix). Kit citations are `kit:<path>:<line>` at
that commit. Consumer citations are `<Repo>/<path>:<line>`, relative to
`/Users/jpurnell/Dropbox/Computer/Development/Swift/Tools/`. A claim without a citation is marked *(inferred)*.

**Method and limits.** I read the kit myself. The consumers were read by four parallel read-only agents, each
briefed with the same list of needs, and I re-checked the claims the build order depends on against the source:
FleetWatch's `+` decoding and its unredacted log line, VaultMCP's `+` decoding, the hub's ALPN pin and its two
listeners, `OPERATIONS.md`, and SwiftMCPServer's OPTIONS-after-auth ordering. What was **not read** is listed in §8;
it matters.

**Work in progress elsewhere (not touched):** the main checkout holds an uncommitted
`project/plans/proposals/DesignProposal_Middleware.md` (request id, access log, GCRA rate limiter) and an untracked
`Tests/SwiftHTTPServiceTests/RequestIDTests.swift`. This survey takes that design as already under way and says
where the consumers confirm it or call for a change to it (§2, item 2).

---

## 0. What the kit does today (the baseline every "kit today" cell refers to)

| Area | Today | Evidence |
|---|---|---|
| Query decoding | RFC 3986 percent-decoding; **`+` stays a plus**; duplicates kept in order | kit:Sources/SwiftHTTPService/Request.swift:130 |
| Bodies | Buffered whole as `Data`; one **global** cap (default 1 MiB, at most 64 MiB) | kit:Sources/SwiftHTTPService/ServiceConfiguration.swift:58-59,173 |
| Responses | `Data` body only (no streaming). Helpers: `.json`, `.empty`, `.notModified`, `.problem`, `setting`, `retrying` | kit:Sources/SwiftHTTPService/Response.swift:37-77 |
| Router | `{param}` whole segments; no tail capture; 404/405 replaceable; 405 carries `Allow`; HEAD served by GET; no automatic OPTIONS | kit:Sources/SwiftHTTPService/Router.swift:19-29,41-50 |
| Middleware | Only the `Middleware` type and `wrap`; none supplied | kit:Sources/SwiftHTTPService/Middleware.swift:11-18 |
| Health | `GET /health`, body `{"status":"ok"}`; the path is configurable, the body is not | kit:Sources/SwiftHTTPService/Health.swift:11,20 |
| Transport refusals (400/408/413/431/500) | Fixed `application/problem+json`; **not replaceable, and they never reach the handler or any middleware** | kit:Sources/SwiftHTTPServiceNIO/SharedRules.swift:80-84; ConnectionHandler.swift:232-236 |
| Thrown handler error | Fixed 500 problem | kit:Sources/SwiftHTTPServiceNIO/SharedRules.swift:60-64 |
| Connection headers | The transport owns `Content-Length`, `Date`, `Connection`, `Transfer-Encoding`, `Keep-Alive` and strips them from handler responses | kit:Sources/SwiftHTTPServiceNIO/SharedRules.swift:70 |
| Keep-alive | On by default. A client's `Connection: close` or HTTP/1.0 is honoured. A second pipelined request closes the connection | kit:Sources/SwiftHTTPServiceNIO/ConnectionHandler.swift:117,199,70-73 |
| Host | HTTP/1.1 requires exactly one `Host`. There is no allow-list | kit:ConnectionHandler.swift:154 |
| Remote address | Socket peer only. No `X-Forwarded-For`, no PROXY protocol | kit:ConnectionHandler.swift:192 |
| Timeouts | Header 10 s, body 30 s, idle 60 s; handler run time unbounded | kit:README.md:53-55,66-67 |
| 413 on an upload in progress | The refusal is written, then the connection closes once that write completes. No drain or linger was found (grep) | kit:ConnectionHandler.swift:234,258 |
| TLS | SwiftTLSKit identity and `reloadTLS()`. `BindExposure` refuses plaintext on an exposed host. Over TLS, ALPN offers h2 and http/1.1 by default (`.http1` narrows it) | kit:HTTPServer.swift:109,120-123,166; ServiceConfiguration.swift:133 |
| Not supported | Upgrade/WebSocket, h2c, trailers, compression, Range, cookies, CORS, form parsing, signals | kit:README.md:65-66 *(the rest by grep)* |

---

## 1. Per-consumer requirement tables

Gap sizes: **none** means the kit covers it today (perhaps with configuration). **small** means a helper or
middleware of under about 150 lines with no design question. **medium** means a design note first. **large** means a
design proposal first.

### 1.1 SwiftPushHub (live: loopback `127.0.0.1:9094` plain, public `0.0.0.0:9095` TLS)

Routes: 11 literal paths, no parameters (`SwiftPushHub/Sources/SwiftPushHubServer/HubRouter.swift:141-152`).

| Need | Evidence | Kit today | Gap | Attacker input? | Risk if wrong |
|---|---|---|---|---|---|
| Host allow-list; refusal is 421 with an empty body, before routing and auth | HubHTTPServer.swift:136-138,152-155; HostAllowList.swift:15-33 | absent | small (middleware) | yes | **High.** It is the public door's misdirected-request and scanner filter |
| Access log covering every request, **including transport refusals** (413, 421). Path redacted to known routes, otherwise `/<seg>/:unmatched` capped at 64 characters. Read by HoneypotTriage | HubHTTPServer.swift:163-184; HubAccessLog.swift:43-49,75-80; CHANGELOG.md:78-91 | absent; in progress as middleware, and that cannot see transport refusals | medium (needs a transport hook) | yes | **High.** Triage would lose records |
| ALPN `http/1.1` only (live bug fix) | HubRuntime.swift:134-138; CHANGELOG.md:58-63 | `protocols: .http1` | none (configuration) | — | Medium. The default would offer h2 |
| Body cap 64 KiB, the same on every route | HubRouter.swift:92 | global `maximumBodyBytes` | none | yes | Low |
| 413 body `{"error":"payload_too_large"}` | HubHTTPServer.swift:140-145,156-157 | fixed problem+json | small (refusal hook) or accept the change | yes | Low. `HubSender` reads `error`/`detail` (HubSender.swift:292) |
| 404/405 bodies `{"error":"not_found"}` / `{"error":"method_not_allowed"}` with `allow` | HubRouter.swift:162-165 | replaceable `notFound`/`methodNotAllowed` | none | — | Low |
| 30 s total per connection (accept to response) | HubHTTPServer.swift:26,114-117 | header 10 s + body 30 s; handler unbounded | small (optional handler deadline) | yes | Medium on 9095 |
| Connection cap 64 | HubHTTPServer.swift:28,93-97 | `maximumConnections` | none | yes | Low |
| One request per connection | HubHTTPServer.swift:17,105,166,191 | keep-alive | none: no client depends on it (`HubSender` uses a fresh ephemeral URLSession per request, HubSender.swift:267) | — | Low |
| Bearer and `WWW-Authenticate: Bearer realm=…`; Basic on `/token`, passed to swift-oauth | HubOAuth.swift:177-185; HubRouter.swift:207-209,251-252,600-605 | handler sets headers | none | yes | Low |
| swift-oauth responses passed through unchanged (status, headers, content type) | HubRouter.swift:607-611 | `Response` takes any headers | none | yes | Low |
| Rate limits keyed by peer, failures-based (10 per 600 s, LRU of 1,000) | TokenRateLimiter.swift:15-24; EnrollmentRateLimiter.swift:14-23 | handler-level; the kit's GCRA is not the same shape | none (stays app code) | yes | Low |
| Statuses 202, 204, 421, 502, 503 | HubRouter.swift:236,331; HubHTTPServer.swift:155 | any status | none | — | — |
| Two listeners in one process sharing state | HubRuntime.swift:220-228 | two `HTTPServer` values | none *(inferred)* | — | Low |
| TLS reload | none; cert read at start (grep) | `reloadTLS()` exists, nothing triggers it | small (trigger helper) | — | Medium. The cert renewed 2026-10-28 with a new key (VaultMCP/deploy/OPERATIONS.md:112-116), and the hub is not in the example deploy hook (`roseclub-ops/config.env.example:92`) *(inferred: stale cert after renewal)* |
| Health `GET /healthz`, text `ok` (outside checks use it) | HubRouter.swift:167-168; CHANGELOG.md:71 | `addHealth(at:)` gives the path but a JSON body | none (register a plain route) | — | Low |
| Graceful shutdown | HubCommand.swift:66-75 (cancels; no drain) | `shutdown()` drains | none (an improvement) | — | — |
| Not used | grep | no SSE, cookies, CORS, redirects, Range, ETag, compression, static files | — | — | — |

### 1.2 FleetWatch (live: `0.0.0.0:9085`, TLS, exposed through UPnP, no proxy)

Routes: about 53, all literal or single-segment parameters (route list:
`FleetWatch/Sources/FleetWatchServer/FleetRouter.swift:183-319` and its extensions).

| Need | Evidence | Kit today | Gap | Attacker input? | Risk if wrong |
|---|---|---|---|---|---|
| **Query `+` decoded as a space** (the page's URLSearchParams writes `scope=fleet%3Aread+fleet%3Aadmin`). First of a repeated name wins | HTTPMessages.swift:21-23,73-83; Page/app.js:34-39; Tests/FleetWatchServerTests/QueryDecodingTests.swift:5-9 | `+` is a plus | small (form decoder) | yes | **High.** Brings back the 2026-10-19 bug: one unknown scope, every token refused with 403 |
| Form bodies (`application/x-www-form-urlencoded`) on `/authorize`, `/authorize/continue`, `/operator/reset*`, `/device_authorization`, `/token` dispatch | FleetRouter.swift:215-217,235-237,246,261 | absent | small (same decoder) | yes | High (login and OAuth) |
| Single-segment "prefix" routes `/enroll/<code>`, `/enroll/<code>/qr.png`, `/legacy/<name>`, `/v1/machines/<id>/request-report` | FleetRouter.swift:224,311-317; FleetRouter+Machines.swift:134-156 | `{param}` | **none.** No tail capture is needed (§6) | yes | Low |
| Security headers on every response: CSP (with `form-action 'self' biz.keepitfun.fleetwatch:`), `nosniff`, `Referrer-Policy: no-referrer`, HSTS, unless the handler set them | FleetRouter.swift:70-77,173-175 | absent; transport refusals would lack them | small (default-headers middleware) plus the refusal hook | — | Medium. Today's own 413 already lacks them (FleetHTTPServer.swift:118-132) |
| Static assets from the bundle: html, js, css, png, zip with `Content-Disposition`, shell script, plus one templated page | FleetRouter.swift:187-203,263-265,307-315; PageAssets.swift:50-70 | `Response(status:headers:body:)` | small (`.html`, `.text`, `.bytes(_:contentType:)` helpers) | — | Low |
| Cache headers: `max-age=86400` on icons; `no-store` (+ `Pragma`) on login, token, device and enrollment | FleetRouter+Notifications.swift:105,122-125; FleetRouter.swift:547-551; FleetRouter+Device.swift:296-332 | handler sets them | none | — | Medium if a default overrides them |
| 302 whose `Location` has a **custom scheme** `biz.keepitfun.fleetwatch://oauth?...` | FleetOAuth.swift:44; FleetRouter.swift:453-466 | handler sets `Location` | small (helper that must not restrict scheme) | — | High if a helper validates http(s) only |
| Error shape `{"error","error_description"}` (OAuth style); clients read both | HTTPMessages.swift:54-57; Page/app.js:197-198; FleetWatchReporterKit/FleetClient.swift:59 | router 404/405 replaceable; transport refusals fixed | small (refusal hook) or accept the change | — | Medium |
| Plain-text 404/405 (no `Allow`); HTML 404 for enrollment | FleetRouter.swift:302,319; FleetRouter+Machines.swift:142 | replaceable; kit adds `Allow` | none (a benign change) | — | Low |
| `Host` read only on `GET /` (answers a "wrong address" page). **A global Host allow-list would break the app**, which reaches the server by IP or `.local` | FleetRouter.swift:183-186,503-511; README.md:328-329 | no allow-list | none, as long as the allow-list stays opt-in | yes | High if made global |
| No CORS, and OPTIONS must not succeed: the passkey defence relies on a cross-site JSON POST needing a preflight that fails | FleetRouter+Passkeys.swift:259-271 | no automatic OPTIONS | none, as long as CORS stays opt-in | yes | **High** if a default answers OPTIONS |
| Origin and `Content-Type: application/json` checks on the 4 passkey routes (403/415) | FleetRouter+Passkeys.swift:263-268 | handler code | none | yes | — |
| Bearer on `/v1/*`; `WWW-Authenticate: Bearer resource_metadata=…, scope=…` (`error="insufficient_scope"` on 403) | FleetRouter.swift:326-337; FleetRouter+Outside.swift:13 | handler sets headers | none | yes | Low |
| Body cap 64 KiB on every route | FleetRouter.swift:67 | global cap | none | yes | Low |
| 30 s per connection; `/v1/check` runs a full probe cycle inside the request | FleetHTTPServer.swift:23,90-101; FleetRouter+CheckNow.swift:34-56 | handler unbounded | small (optional handler deadline) | yes | Medium |
| 64 MiB zip download, read whole into memory | Downloads.swift:16,38-52 | `Data` body; no write timeout | none *(inferred: memory, not correctness)* | — | Low |
| Connection cap 64; one request per connection | FleetHTTPServer.swift:25,72-80,86,148,158 | `maximumConnections`; keep-alive | none: clients are ephemeral URLSession, curl, browser (FleetWatchReporterKit/SystemAdapters.swift:62) | — | Low. Keep the idle timeout short so idle sockets don't fill the cap |
| Access log: EventJournal, peer, method, redacted path (`/enroll/:code`, `/legacy/:name`, …), status, auth outcome; never query, headers or body | FleetAccess.swift:72-107,170-203 | in progress as middleware; needs route-pattern redaction | medium (pattern in context; transport hook) | yes | Medium |
| TLS reload: polls `reloadIfChanged()` hourly | FleetWatchServerCommand.swift:184-191 | `reloadTLS(.ifChanged)` (SwiftTLSKit/Sources/SwiftTLSKit/ReloadableServerTLS.swift:21), with no trigger | small (trigger helper) | — | Medium |
| Shutdown: no signal handler; task cancel; in-flight requests cut | FleetWatchServerCommand.swift:170-195 | `shutdown()` | none (an improvement) | — | — |
| Remote address used only in the access log; must **not** trust `X-Forwarded-For` | FleetHTTPServer.swift:88 | socket peer | none (and correct) | yes | High if XFF were trusted by default |
| Rate limits: all app-level, none keyed by IP (sign-in global 5/15 min, enrollment, per-machine buckets …) | OperatorLogin.swift:59-63; EnrollmentService.swift:75-94 | — | none | yes | — |
| No SSE, WebSocket, cookies, sessions, compression, ETag, Range, h2 | grep; Page/app.js:9,623 (polls every 60 s) | — | — | — | — |
| *Unexpected:* every request's **unredacted** path goes to os.Logger as `.public`, which puts live one-time enrollment codes in the unified log | FleetRouter.swift:176 | — | FleetWatch fix, not kit | — | **Security finding** for FleetWatch |
| *Unexpected:* the app's TLS request carries no SNI, or one that does not match the certificate, and still has to receive the `fleet.keepitfun.biz` certificate | README.md:328-329; FleetWatchKit/FleetServer.swift:12 | single SwiftTLSKit identity *(inferred: same as today)* | none *(inferred)* | — | Medium. Check during the recorded exchange |

### 1.3 VaultMCP `vault-mcp-web` (live: `0.0.0.0:9100`, TLS)

The router is in the `VaultMCPWeb` library (`VaultMCP/Sources/VaultMCPWeb/WebRouter.swift`), the listener in
`VaultMCPWebMain/{main,HTTPHandler}.swift`.

| Need | Evidence | Kit today | Gap | Attacker input? | Risk if wrong |
|---|---|---|---|---|---|
| **Tail capture**: `/ui/doc/<rest>`, `/ui/tag/<rest>`, `/ui/folder/<rest>`; document ids contain `/`; `..` refused | WebRouter.swift:132-181,772,991 | absent (by design) | **medium (design: D3)** | yes | **High.** Every document page |
| Path decoded once whole (so `%2F` becomes `/`) | HTTPHandler.swift:146-153 | decoded per segment; dot segments refused | none if tail capture joins the decoded segments *(design point)* | yes | Medium. `%2F` in an id would change meaning |
| **Query and form `+` as a space**; first duplicate wins; bad `%` left as written | WebRequest.swift:55-87 (decode at :84-86); search form WebRouter.swift:1056 | `+` is a plus; a bad escape is a 400 | small (form decoder) | yes | **High** (search with spaces). The stricter escape handling is a behaviour change to record |
| Cookies: `vault_session`, `Path=/ui; Expires; HttpOnly; Secure (TLS); SameSite=Strict`; cleared with `Max-Age=0`; several `Cookie` fields joined with `;` | SessionCookie.swift:38-90; HTTPHandler.swift:123-127 | absent (HTTPFields keeps several `Set-Cookie`) | small (typed `SetCookie` builder + `Cookie` parser) | yes | **High.** Attribute mistakes are session-security bugs |
| 303 redirects to a relative `/ui/...` | WebRouter.swift:1215-1221 | handler sets `Location` | small (same redirect helper) | — | Low |
| Security headers on **every** response: CSP, `Referrer-Policy`, `Cache-Control: no-store`, `nosniff`, `X-Frame-Options: DENY` | PageLayout.swift:40-50; RequestMethod.swift:46-49 | absent; transport refusals lack them | small (middleware) + refusal hook | — | Medium |
| GET, POST, HEAD (HEAD keeps Content-Length); others 405 without `Allow` | RequestMethod.swift:24-52; HTTPHandler.swift:42-57,157-159 | HEAD via GET; 405 with `Allow` | none | — | Low |
| Body cap 16 KiB; over it the connection closes **with no response** (deliberate) | main.swift:17-22,571; HTTPHandler.swift:199-204 | 413 problem then close | none (behaviour change to record) | yes | Low |
| Idle 30 s | main.swift:24-29,562-565 | `idleTimeout` | none | yes | Low |
| Content types with `; charset=utf-8` (html, css, js, json) | WebRouter.swift:1152-1213 | handler sets them | small (helpers) | — | Low |
| Access log: peer, method, redacted decoded path (`/ui/doc/:id` …), status, auth outcome plus subject id; written after the response; uses SwiftMCPServer's `AccessLogSink` | HTTPHandler.swift:53-55,97-100 | in progress | medium (route pattern for redaction; subject from the context; refusals) | yes | Medium |
| Header-injection refusal (CR, LF, NUL) in response values | WebResponse.swift:27-37 | HTTPFields validates values *(inferred: swift-http-types refuses invalid field values)* | none *(verify)* | yes | Medium |
| TLS: no ALPN (HTTP/1.1 only); restarted by the certbot hook | main.swift:519-560; OPERATIONS.md:106-115 | `.http1`; reload optional | none | — | Low |
| Bind: loopback default, TLS otherwise | WebOptions.swift:177-259 | `BindExposure` | none | — | — |
| Pipelining: responses are async with no pipeline handler, so they could come back out of order *(inferred)* | main.swift:566-573; HTTPHandler.swift:75-77 | refused safely | none (an improvement) | yes | — |
| No SSE, Range, ETag, compression, request ids, health route, h2 | grep | — | — | — | — |

### 1.4 SwiftMCPServer transport (and every service on it)

Services on it: businessMathMCP 8080, GeoSEOMCP 8081, DevGuidelinesMCP 8082, SearchOperatorMCP 8083, ijs-mcp-server
9087, vault-mcp-server 9086/9091 (plus 8090 loopback), ConformanceServer 3002 (DevGuidelinesMCP/README.md:144-170;
ijs-mcp-server/README.md:14-28; VaultMCP/deploy/OPERATIONS.md:10-19). None of the five named services configures
the transport in code. Everything comes from flags and environment variables in launchd plists that are not in the
repos. Paths below are under `SwiftMCPServer/Sources/SwiftMCPServer/`.

| Need | Evidence | Kit today | Gap | Attacker input? | Risk if wrong |
|---|---|---|---|---|---|
| **Streaming responses / SSE**: head first, then events, `writeAndFlush` per event; four stream kinds (GET `/mcp`; a POST that **turns into a stream mid-handler** when a progress notification or server-to-client request appears; `subscriptions/listen`; legacy `/mcp/sse`) | Transport/NIOHTTPConnection.swift:88-110,151-163; HTTPServerTransport.swift:321-329; Response/HTTPResponseManager.swift:186-253; Transport/MCPServerHandler.swift:961-1161 | absent | **large (design: D2)** | medium | Without it nothing in MCP works |
| SSE framing: `event:` plus one `data:` line per payload line, split on any newline (CR, CRLF, U+2028/9); heartbeat `:\n\n` every 30 s | Session/SSESession.swift:62-117; StreamableSessionManager.swift:123-128 | absent | part of D2 | medium (a CRLF in data would inject an event) | High |
| Stream lifetime vs the kit's idle and body timers: streams live up to 30 min (session) or indefinitely | StreamableSessionManager.swift:37,153-163; HTTPResponseManager.swift:110 | idle 60 s would cut quiet streams | part of D2 (writes reset the idle timer, or streams are exempt) | — | High |
| Backpressure: today an unstructured Task per event, unbounded, no guaranteed order *(inferred)* | SSESession.swift:99-101 | — | part of D2 (an awaitable writer with a bound) | medium (memory under a slow reader) | Medium |
| Anti-buffering headers incl. `Connection: keep-alive`, `X-Accel-Buffering: no` | MCPServerHandler.swift:983-986,1098-1104 | transport owns `Connection` | part of D2 | — | Low |
| Sessions: `Mcp-Session-Id` (64 hex), optional on POST, 404 if unknown, DELETE ends it, 1800 s idle | MCPServerHandler.swift:695-696,1032-1062,1164-1178; Session/SessionToken.swift:28-41 | header access only | none (app-level) | yes | — |
| Body ceiling per listener, default 4 MiB, inclusive; **413 before the Host check and before auth**; the rest of the upload drained, then close after a 2 s linger so an RST does not eat the 413 (tested 30/30) | HTTPServerTransport.swift:44,140,154; MCPServerHandler.swift:105,129-208; Tests/SwiftMCPServerTests/RequestBodyCeilingTests.swift:69-232 | global cap (fine for one listener); **no drain or linger found** | small to medium (drain/linger on refusal; measure first) | yes (DoS) | Medium. Clients may see a reset instead of a 413 |
| Host and Origin allow-list (`.loopback`/`.named`/`.any`; missing Host refused; missing Origin admitted; `Origin: null` refused); 403 text; runs before routes and auth | Transport/AllowedHosts.swift:28-106; MCPServerHandler.swift:248-255 | absent | small (same middleware as the hub, with Origin) | yes (GHSA-w48q-cv73-mx4w) | **High** (DNS rebinding) |
| CORS on every response: `ACAO: *`, methods, headers, expose `Mcp-Session-Id`; **credentials banned**; OPTIONS answered 204 on any path with `Max-Age: 86400` | Transport/MCPHTTPRoute.swift:72-88; MCPServerHandler.swift:273-276,1390-1416 | absent | small to medium (opt-in CORS middleware with preflight) | yes | Medium. Wildcard is safe only while credentials stay banned |
| OAuth AS endpoints (two `.well-known` documents, `/register`, `/authorize`, `/authorize/consent`, `/token`): form bodies, HTML consent page, 302 with `Location`, `no-store` + `Pragma` | MCPServerHandler.swift:328-489,540-573; swift-oauth `OAuthHTTPHandler` (not fully read) | partial | small (form decoder, html, redirect) | yes | High |
| **`+` in the `/authorize` query is NOT decoded as a space** today (last value wins) | swift-oauth `OAuthHTTPHandler.swift:141-209` (SwiftMCPServer checkout) | `+` is a plus (consistent) | none, **but it conflicts with FleetWatch and VaultMCP** (open question Q1) | yes | Medium |
| Auth: API key (`Bearer`, `ApiKey` or bare), then OAuth bearer; **no `WWW-Authenticate` anywhere** | Auth/APIKeyAuthenticator.swift:115-198; MCPServerHandler.swift:1216-1260 | handler-level | none (an improvement is possible) | yes | — |
| `MCPHTTPRoute` extension routes, GET only, segment-boundary prefix match, credential segments redacted in the access log. Used only by VaultMCP's `/calendar/<token>/<scope>.ics` | Transport/MCPHTTPRoute.swift:28-261; VaultMCP/Sources/VaultMCP/Calendar/CalendarFeed.swift:85-92 | `{param}` (the `.ics` suffix is checked in the handler) | none | yes | Medium (the token must be redacted in logs) |
| Calendar feed: `text/calendar; charset=utf-8`; `Cache-Control: no-store` and `X-Robots-Tag: noindex, nofollow` on **every** response, refusals included; 404 for a bad token | CalendarFeed.swift:77-80,109-146 | handler sets them; transport refusals would lack them | small (refusal hook) | yes | **High** if lost: caches and crawlers would keep a credential |
| Access log: peer, method, redacted path, status, auth outcome, credential name; written when the head goes out (streams included) | MCPServerHandler.swift:82-90,1274-1316; AccessLog/AccessRecord.swift:26-61 | in progress | medium (stream-aware: log at head time) | yes | Medium |
| Error shapes: text/plain (`Unauthorized`, `Forbidden`, `Payload Too Large`, `Not Found` …); JSON-RPC errors mapped to 400/404/200; a 504 timeout with a JSON-RPC body | MCPServerHandler.swift:922-947; HTTPResponseManager.swift:286-297,402-418 | problem+json | small (refusal hook) or accept the change | — | Medium. MCP clients may read status only *(inferred)* |
| Health `GET /health`, text `OK`; `GET /mcp` without SSE `Accept` returns server info without auth | MCPServerHandler.swift:305,380-402 | `addHealth` (JSON body) | none (register a plain route) | — | Low |
| TLS: NIOSSL, TLS 1.2, **no reload, no ALPN** | HTTPServerTransport.swift:231-243 | kit + SwiftTLSKit | none (an improvement) | — | — |
| **No limits at all** on header bytes, connections, header/body/idle time | HTTPServerTransport.swift:247-266 | every limit | none (a large improvement) | yes | — |
| Exposed plaintext allowed by the transport | BindHost.swift:23-72 | refused | none: every service binds 0.0.0.0 **with** TLS (docs cited above) | — | Low. A proxy-fronted deployment must bind loopback (businessMathMCP/README.md:67) |
| Keep-alive: `Connection: close` sent but the connection not closed | MCPServerHandler.swift:1355,1375-1376 | keep-alive | none | — | Low |
| Shutdown: no drain; no signal handling | HTTPServerTransport.swift:280-308 | `shutdown()` drains | none, **once streams are ended at shutdown** (part of D2) | — | Medium |
| No request ids, rate limiting, compression, ETag, XFF, h2 | grep | — | — | — | — |

Defects found in SwiftMCPServer while reading. All are *(inferred from reading, not run)*, and a recorded exchange
should pin each one before deciding whether a migration preserves it or fixes it:
1. An unauthenticated CORS preflight to `/mcp` gets **401**, because OPTIONS is answered after the auth check
   (MCPServerHandler.swift:263-276; I re-read this ordering).
2. A GET `/mcp` stream is closed at about 30 minutes, because heartbeats do not refresh the session
   (StreamableSessionManager.swift:63,153-163).
3. Subscription streams get no heartbeats and are never removed (SubscriptionStreamRegistry.swift:98).
4. The 300 s pending-request timeout can write a second head onto a stream that already has one
   (HTTPResponseManager.swift:360-378).
5. The `x-mcp-header` / `Mcp-Param-*` check is off in every production server; only ConformanceServer wires it
   (MCPServer.swift:629-641; ConformanceServer/main.swift:24).
6. CORS `Access-Control-Allow-Headers` omits the 2026 `Mcp-*` headers (MCPHTTPRoute.swift:72-77).

### 1.5 ijs-dashboard-server (already on the kit; live on Teletran 2, port 9140, TLS)

Not a migration, but it is the evidence for what the kit lacks: everything below it wrote itself.

| Need | Evidence (`ijs-dashboard-server/`) | Kit today | Gap |
|---|---|---|---|
| Per-request audit line (JSON to stderr), including the 500 path | Sources/DashboardServerRuntime/JSONLinesAudit.swift:22-41; DashboardService.swift:134 | in progress (access log) | medium (refusals) |
| Bearer header parsing (scheme case, RFC 6750 characters, 512-byte cap, one field) | Bearer.swift:20-26 | absent | small (a `BearerToken` parser is generic) |
| Rate limiter, fixed window per `remoteAddress` (30/60 s, 1024 keys) on passkey routes | Passkeys/RateLimiter.swift:16-60; PasskeyRoutes.swift:129-132 | in progress (GCRA) | none once it lands |
| `Cache-Control: no-store` helper | PasskeyRoutes.swift:189-191 | absent | small |
| Tenant prefix `/t/{tenant}/…` resolved before the router | DashboardService.swift:116; Routes.swift:45 | `{param}` would do *(inferred)* | none |
| SIGHUP calls `reloadTLS()`; nothing sends SIGHUP after renewal | Sources/DashboardServerRuntime/ServerRuntime.swift:59,68-80; project/master_plan.md:142 | hook only | small (trigger helper) |
| Kit named by path, not by tag | Package.swift:23 | v0.2.0 tagged | housekeeping |

### 1.6 Every other listener found (grep for `NIOHTTP1`, `HTTPServerRequestPart`, `ServerBootstrap`, `NWListener`, Python `http.server`, `nc -l`)

| Package / file | What it is | Verdict |
|---|---|---|
| SwiftWebAuthn `Sources/CaptureHTTP/HTTPServer.swift:65-247` (NWListener, 127.0.0.1:8099, own parser, always `200` and `Connection: close`) | dev tool that captures WebAuthn fixtures from a phone; 5 literal routes (`Sources/webauthn-capture/Capture.swift:157-191`) | **Migrate (optional).** Needs only `.html`. It adds a kit dependency to SwiftWebAuthn for a dev executable |
| SwiftMCPClient `Sources/MCPClient/LoopbackRedirectListener.swift:82-200` | OAuth RFC 8252 loopback redirect catcher in a client library | Out of scope: the kit plus SwiftTLSKit in a client library to catch one GET |
| swift-sdk `Sources/MCPConformance/Server/HTTPApp.swift:114-433` | upstream fork's conformance server; needs SSE | Out of scope (upstream) |
| Ignite `server.py` (Python `http.server`, all interfaces, 8000) | third-party static preview | Out of scope |
| VaultMCP `deploy/ask-the-house/ask_the_house.py:232-247` (aiohttp, TLS, 9088 live per OPERATIONS.md:16; the code default is 8787) | **Python**, not Swift: voice bridge, plus a proxy for `/calendar/…` to 9091 | Out of scope. It is a client of the calendar feed, so the feed's recorded exchange must include it |
| sim-tap `Serve.swift` (Unix socket, NDJSON) | not HTTP | Out of scope |
| SwiftCLIKit / swift-cli-kit-auth SSH | SSH | Out of scope (grep only) |
| Test stubs: SwiftMCPClient Tests (5), swift-oauth RedirectWireStub, SwiftTLSKit Loopback, SwiftPenTest ALPN, roseclub-ops `nc -l` | wire-level doubles that must misbehave | Out of scope. SwiftTLSKit's would also be circular |
| ijs-dashboard-api, quality-gate-dashboard, panLAN, quality-gate-swift ServerSurface | no listener | — |

---

## 2. Prioritised build order for the missing kit features

The ranking weighs four things, in this order: (a) **dependency**, meaning whether another feature or a first
migration is blocked on it; (b) **security surface**, meaning whether it parses attacker input or protects a public
door; (c) **consumers**, meaning how many need it; (d) **size**. Release groupings follow migration readiness, so
that each release unblocks one consumer and that consumer's migration tests the release.

| # | Feature | Consumers | Security | Size | Generic and cheap, or design first? |
|---|---|---|---|---|---|
| 1 | **Transport observer and refusal hook**: (i) an event per finished exchange (status, bytes, duration, peer, method, path, and whether the transport or the handler answered), so the access log sees 400/408/413/431/500; (ii) a way for a server to decorate or replace transport refusals (security headers, `no-store`, its own error shape) | hub (triage), FleetWatch, Vault web, calendar feed, MCP, ijs-dashboard | high | medium | **Design note first.** Amend `DesignProposal_Middleware.md`: as written, its access log is a `Middleware` and cannot see transport refusals, and the hub's honeypot triage depends on them (SwiftPushHub/CHANGELOG.md:78-91). The refusal body's rule "never repeats anything the peer sent" (kit:README.md:63) must survive the hook |
| 2 | **Access log + request id** (in progress) with **route-pattern redaction**: the router puts the matched pattern (for example `/enroll/{code}`) in the context, so the log never needs per-server redaction code. Unmatched paths become `/<first>/:unmatched` | all six | high (logs hold credentials: enrollment codes, calendar tokens) | small + #1 | Already designed; add the pattern-in-context point. Note FleetWatch's existing leak (FleetRouter.swift:176) as the cautionary case |
| 3 | **Host (and Origin) allow-list middleware**, opt-in, with a configurable refusal (hub: 421 empty; MCP: 403); duplicate Host already refused | hub (public), MCP (all services) | high | small | Generic and cheap. Must never be on by default (FleetWatch breaks: FleetRouter.swift:503-511) |
| 4 | **Form decoding**: `FormFields` for `application/x-www-form-urlencoded` bodies **and** queries with `+` as a space, first-wins and all-values accessors, the same strictness as `Request` (NUL, bad UTF-8 refused) | FleetWatch, Vault web, MCP OAuth, hub `/token` (passed to swift-oauth) | high | small | Cheap, but one decision first (Q1): leave `Request.query` as RFC 3986 and add a form view of the raw query, or change `query`. Recommendation: add, don't change (`query` stays bytes-faithful; `request.formQuery` is the WHATWG reading) |
| 5 | **Response helpers**: `.html`, `.text`, `.bytes(_:contentType:)`, `.redirect(to:status:)` (302/303/307/308, **any scheme**, CR/LF refused), `noStore()` | FleetWatch, Vault web, MCP OAuth, webauthn-capture, ijs-dashboard | low | small | Generic and cheap |
| 6 | **Default-headers middleware** (CSP, nosniff, Referrer-Policy, HSTS, X-Frame-Options; set only when the handler has not), also applied to refusals through #1 | FleetWatch, Vault web, calendar feed | medium | small + #1 | Generic and cheap |
| 7 | **Cookies**: a typed `SetCookie` (Path, Domain, Expires/Max-Age, HttpOnly, Secure, SameSite; name and value validated) and a strict `Cookie` parser (several fields joined, first-wins) | Vault web | high | small | Cheap, but test-heavy (attribute rules from RFC 6265bis) |
| 8 | **TLS-reload and shutdown triggers**: a helper that wires SIGTERM/SIGINT to `shutdown()` and SIGHUP and/or a timer to `reloadTLS(.ifChanged)` | all six (none has both today; the hub reloads never) | medium (stale certs) | small | Generic and cheap. It is the open master-plan item "a reload trigger is the executable's" (project/master_plan.md:70); this says it should be the kit's |
| 9 | **Tail capture** `{name...}`: last segment only, at least one segment, decoded segments joined with `/` after per-segment validation (dot segments already refused), lowest specificity | Vault web | high (paths) | medium | **Design note first (D3).** Only one consumer needs it, but that consumer cannot move without it |
| 10 | **Drain and linger on early refusal**: after a 413 or 431 on HTTP/1.1, read and drop up to a bound or for up to N seconds before closing, so the client receives the refusal instead of an RST | MCP (tested behaviour), hub, FleetWatch *(inferred)* | medium (DoS bound) | small to medium | Measure first: write the test MCP has (RequestBodyCeilingTests.swift:154-166) against the kit; build only if it fails |
| 11 | **Optional handler deadline** (`Limits.handlerTimeout`, off by default; 503/504 problem; not applied to streams) | hub and FleetWatch parity (both 30 s total) | medium | small | Cheap, but it touches the transport; decide Q5 first |
| 12 | **Streaming responses**: a body that is an async writer (awaitable `write` with a bounded buffer, `flush`, `finish`); a handler can **start a stream after it begins running**; idle and body timers suspended or reset by writes; HTTP/1.1 chunked and HTTP/2 DATA; shutdown ends streams; an `SSEWriter` on top (line splitting on every newline form, comments as heartbeats, optional `id`/`retry`) | MCP (every service), swift-sdk (out of scope) | medium | **large** | **Design proposal first (D2).** It changes `Response` (today a `Data` body, `Equatable`) and both pipelines |
| 13 | **CORS middleware with automatic preflight** (opt-in; wildcard origin only when credentials are banned; preflight answered **before** auth) | MCP | medium | small to medium | After #12, because only MCP needs it, and MCP cannot move before streaming |
| 14 | **`WWW-Authenticate` / Bearer helpers** (parse `Authorization: Bearer`, build challenges with `resource_metadata`, `scope`, `error`) | FleetWatch, hub, ijs-dashboard, MCP (missing today) | high | small | Cheap; any release |
| 15 | Rate limiter (in progress, GCRA) | ijs-dashboard (passkey routes) only. Every other limiter is failures-based app logic keyed on user, machine or global | medium | small | Already designed. Its pull from consumers is lower than its position in the plan suggests |

**Not needed by any consumer, so not to be built:** WebSocket/Upgrade, compression, Range/partial content,
`If-Modified-Since`, X-Forwarded-For / PROXY protocol (no consumer is behind a proxy, and FleetWatch is directly on
the internet, where trusting XFF would be spoofable), per-route body limits (each listener has one cap; see §6),
multipart, sessions, metrics endpoints, HTTP/2 features beyond v0.2.0.

### Proposed releases

| Release | Contents | Unblocks |
|---|---|---|
| **0.3.0: observability and the public door** | #1 transport observer + refusal hook, #2 access log + request id (+ pattern redaction), #3 Host/Origin allow-list, #8 reload and shutdown triggers, #14 Bearer helpers, #15 rate limiter (already started), #10 measured and built if needed | **SwiftPushHub**, and ijs-dashboard can delete its own audit and bearer code |
| **0.4.0: browsers and forms** | #4 form decoding, #5 response helpers, #6 default headers, #7 cookies, #9 tail capture, #11 handler deadline (if Q5 is yes) | **FleetWatch**, **vault-mcp-web**, webauthn-capture |
| **0.5.0: streaming** | #12 streaming + SSE, #13 CORS/preflight | **SwiftMCPServer** and its services, including VaultMCP's calendar and MCP instances |

The order within 0.3.0 matters: #1 comes before #2, because an access log built as middleware first would have to be
rebuilt.

---

## 3. Migration readiness per consumer

Every migration also keeps the package's existing tests unchanged and adds a **recorded exchange**: before changing
anything, record status, the headers named below, and the body for a fixed set of requests, then replay them
against the migrated server. Each difference is either written down as intended or treated as a bug
(`MigrationPlan_HandRolledServers.md` §4).

### SwiftPushHub, needs 0.3.0
- Kit features: #1, #2, #3, #8; configuration `protocols: .http1`, `maximumBodyBytes: 64 KiB`,
  `maximumConnections: 64`; custom `notFound`/`methodNotAllowed`; a plain `/healthz` route; two `HTTPServer`s in
  one process.
- Recorded exchange, on **both** doors: every route with a good token, a bad token and no token; a wrong `Host` on
  9095 (421, empty body) and on 9094; a body of 64 KiB + 1 (413 and its body shape); an unknown path and a wrong
  method (body plus `allow`); `/token` with Basic auth (swift-oauth's bytes passed through); the 429s (no
  `Retry-After` on `/token` and `/enroll`, `Retry-After` on the channel limit); the ALPN result (`http/1.1`); and
  the access-log records for each of these, compared field by field with what HoneypotTriage reads.
- Before it moves: decide whether a 30 s total deadline is kept (Q5), and wire TLS reload on 9095 (#8).

### FleetWatch, needs 0.4.0 (and 0.3.0)
- Kit features: #2 with pattern redaction, #4, #5, #6 and #1 for refusals, #8 (hourly `ifChanged`), #11 (Q5);
  configuration with 64 KiB, 64 connections, a short idle timeout; custom 404/405 (plain text, so the recorded
  exchange shows whether to keep them); **no** Host allow-list, **no** CORS, **no** automatic OPTIONS.
- Recorded exchange: `GET /authorize?…scope=fleet%3Aread+fleet%3Aadmin…` (the 2026-10-19 regression); every form
  POST with `+` and `%20` spaces and a repeated name; the 302 to `biz.keepitfun.fleetwatch://oauth?…`
  byte for byte; every static asset (content type, `Content-Disposition`, cache headers); the security headers on
  a 200, a 404, a 413 and a 400 from the transport; `OPTIONS` on a passkey route (must not be 2xx, and must carry
  no `Access-Control-*`); a cross-site passkey POST (403/415); `GET /` with a wrong `Host` (the "wrong address"
  page); `WWW-Authenticate` on 401 and 403; HEAD on a GET route (a change from 405: write it down); the 64 MiB
  zip download timed on a slow link; the app over IP and `.local` with no SNI (certificate served); and whether the
  app negotiates h2 once it is offered (Q6).
- Fix first, in FleetWatch itself: the unredacted enrollment code in os.Logger (FleetRouter.swift:176).

### vault-mcp-web, needs 0.4.0 (and 0.3.0)
- Kit features: #9 tail capture, #4, #7 cookies, #5, #6 + #1, #2 (with subject id from the context);
  configuration with 16 KiB, idle 30 s, `.http1` (or Q6).
- Recorded exchange: `/ui/doc/<id with slashes>`, `%2F` inside an id, `..` (refused), `/ui/search?q=two+words`,
  a bad `%` escape (today left as written, in the kit a 400: write it down); the sign-in POST (303, the exact
  `Set-Cookie` attributes with and without TLS), sign-out (`Max-Age=0`), several `Cookie` fields; CSRF failures;
  every security header on a 200, the HTML 403/404/503 pages, and the transport's 400/413/431; a body of 16 KiB + 1
  (today the connection closes silently, in the kit a 413: write it down); HEAD (`Content-Length` kept);
  `PUT` (405, now with `Allow`); and the access-log records.

### SwiftMCPServer and every service on it, needs 0.5.0 (and 0.3.0, 0.4.0)
- Kit features: #12 streaming + SSE, #13 CORS, #3 with Origin, #10 (measured), #4/#5 for the OAuth endpoints, #1
  (text/plain refusals, or accept problem+json), #2 written at head time for streams, #14; configuration with a
  4 MiB body and the stream-aware idle rule.
- Recorded exchange: `initialize` (`Mcp-Session-Id`), a POST answered with JSON, a POST that turns into SSE
  mid-handler (progress, then the result as the last event), `GET /mcp` with and without `Accept:
  text/event-stream` (a stream with auth, server info without), heartbeats at 30 s, a stream kept for 31 minutes
  (pins defect 2), `subscriptions/listen`, DELETE, unknown and missing session ids; a payload with CR, CRLF and
  U+2028 in it; the 413 at 4 MiB + 1 delivered (not reset) 30/30 times, before Host and auth; a Host/Origin matrix
  (missing Host, `Origin: null`, rebinding); preflight with and without credentials (pins defect 1); the OAuth
  flow end to end (form, consent HTML, 302, token with `no-store` and `Pragma`); `/health` (text `OK`); the 504
  timeout body; and, for VaultMCP's calendar route on 9091, `.ics` content type, `no-store` and `X-Robots-Tag` on
  200, 404 and 503, the token absent from the access log, and a fetch through ask-the-house's proxy.
- Migration shape: the plan's §4.4 ("not wholesale") stands until 0.5.0 exists. After that the owner's decision
  (migrate everything) applies.

### ijs-dashboard-server, already on the kit
- Move to a tagged version. After 0.3.0, replace its audit, bearer and rate-limit code with the kit's, and verify
  with its existing tests plus the audit-line comparison.

### webauthn-capture (optional), needs 0.4.0 (`.html`)
- Recorded exchange: its 5 routes; real status codes instead of `200` for every error (a change: write it down).

---

## 4. What changes in the existing plan's order

The plan put SwiftPushHub first because "nothing live depends on it". That premise is gone (§6, item 1). It still
belongs first, because it needs the least (one release, no browser surface, no streaming) and because its public
door is the best test of #1 to #3. But its risk is no longer "low": it carries real alerts from five senders, and it
should get the run-beside, replay, then switch procedure the plan reserved for FleetWatch (§4.2 step 5).

---

## 5. Facts that are drift in the kit's own docs

- `README.md:5` still says "pre-0.1, untagged" while v0.2.0 is tagged and the master plan says so
  (project/master_plan.md:87).
- `project/master_plan.md:20,33` names `swift-nio-ssl` as a direct dependency; README.md:71-73 says TLS comes
  through SwiftTLSKit and lists `swift-nio-http2`, which the master plan omits.
- Master plan Roadmap Phase 3 ("0.1.0: … then the tag", :135) is unticked though 0.1.0 and 0.2.0 shipped.

These are recorded, not fixed, here (this commit is docs-only and limited to this file).

---

## 6. What `MigrationPlan_HandRolledServers.md` got wrong, or what has changed since

| # | The plan says | The fact now | Evidence |
|---|---|---|---|
| 1 | Hub: "bootstrapped; nothing here runs yet … nothing live depends on it" (§4.1) | **Live** on Teletran 2 since 2026-10-27 on loopback 9094 (plain), and since 2026-10-28 also on **public 0.0.0.0:9095 with TLS** for `push.keepitfun.biz`, in one process. It delivers real alerts (honeypot to iPhone; an outside sender's event reached both devices). Its README is still stale (README.md:7), and so is `HubConfig.standard`'s port 9086 (HubConfig.swift:160-166) | SwiftPushHub/CHANGELOG.md:64-77,143,150; HubRuntime.swift:220-228 |
| 2 | Hub is "loopback-only plain HTTP until 4d" | 4d shipped: a public TLS door with a Host allow-list (421) and an access log read by honeypot triage | CHANGELOG.md:67-91; HostAllowList.swift:15-33 |
| 3 | Hub listener 144 lines, router 232 | 197 and 612 | `wc -l` at survey time |
| 4 | FleetWatch needs tail wildcards (`/legacy/*`, `/enroll/*`) (§3, D3) | All are **single segments** that `{param}` expresses. FleetWatch needs no tail capture. The real tail need is **vault-mcp-web** (`/ui/doc/<rest>`) | FleetRouter.swift:311-317; VaultMCP WebRouter.swift:132-181,991 |
| 5 | FleetWatch needs "redirects, cookies" for its OAuth/login flow (not read) | **No cookies at all** (tokens in `sessionStorage`, tickets in hidden fields). One 302, to a custom scheme. Cookies are needed only by vault-mcp-web | grep `Set-Cookie`; Page/app.js:63; FleetRouter.swift:453-466 |
| 6 | Calendar feed: in the VaultMCP web target, read by a client that "can only fetch over plain HTTP" (§4.3) | The feed is an `MCPHTTPRoute` in **vault-mcp-server** on SwiftMCPServer's transport, served on **0.0.0.0:9091 with TLS**. `deploy.sh` refuses plaintext off loopback. The "plain HTTP" note dates from when a proxy did TLS on :8091. So the feed migrates with SwiftMCPServer (0.5.0), not with the web target | VaultMCP/Sources/VaultMCPMain/Main.swift:519-521; CalendarFeed.swift:85-92; deploy/OPERATIONS.md:14; deploy.sh:181; VaultMCP/CHANGELOG.md:688,1012 |
| 7 | VaultMCP web target is "794 lines" (`HTTPHandler` 180 + `main` 614) | 205 + 636 for the listener, plus the `VaultMCPWeb` library (router, pages, cookies, request types) that holds the HTTP behaviour | `wc -l`; VaultMCP/Sources/VaultMCPWeb/ |
| 8 | "Per-route body limits: Hub (64 KiB) vs the default" | The hub has one cap for every route. No consumer mixes caps within one listener. A global cap per server suffices | HubRouter.swift:92; FleetRouter.swift:67; VaultMCP main.swift:17-22; SwiftMCPServer HTTPServerTransport.swift:44 |
| 9 | One request per connection: "check each client tolerates" keep-alive | Checked by reading: the hub's and FleetWatch's clients use ephemeral URLSessions, curl or browsers, and none depends on a close. Not measured | HubSender.swift:267; FleetWatchReporterKit/SystemAdapters.swift:62 |
| 10 | SwiftMCPServer limits "not found by name, which is not the same as their being absent" | They **are** absent: no header-size, connection or timeout limits. The only bound is the 4 MiB body | HTTPServerTransport.swift:247-266 |
| 11 | `MCPHTTPRoute` routes "could be registered on a kit Router" | No MCP service registers one, except VaultMCP's calendar | each service's main.swift; CalendarFeed.swift:85-92 |
| 12 | Survey of hand-rolled HTTP: five servers | Also: SwiftWebAuthn `webauthn-capture` (a migration candidate), ask-the-house (Python, a client of the feed), swift-sdk's conformance server, Ignite's Python preview, and test stubs (§1.6) | §1.6 |
| 13 | §1: "The transport is unmerged and unproven" | Merged, v0.2.0 with HTTP/2, `ijs-dashboard-server` live on it since 2026-10-28 (port 9140) | project/master_plan.md:60-87 |
| 14 | The hub's TLS (implied: SwiftTLSKit handles reload) | The hub never reloads. The certificate renewed with a new key on 2026-10-28 *(inferred: 9095 may serve a stale certificate until a restart)* | grep `reload` in SwiftPushHub/Sources; OPERATIONS.md:112-116 |
| 15 | — | VaultMCP's `OPERATIONS.md` agent table lists the hub as "9094, loopback only", which conflicts with the hub's own changelog (9095 public) | VaultMCP/deploy/OPERATIONS.md:18 vs SwiftPushHub/CHANGELOG.md:67-73 |

---

## 7. Open questions only the owner can answer

- **Q1: `+` in queries.** FleetWatch and vault-mcp-web need `+` read as a space. SwiftMCPServer's swift-oauth
  `/authorize` reads it as a plus. The kit reads it as a plus. Add a form view (recommended), or change `query`?
  If the MCP OAuth endpoint moves onto the form view, its behaviour changes for a `+` in `scope`. Is that wanted?
- **Q2: error shapes on transport refusals.** Should migrated servers keep their own shapes (FleetWatch OAuth-style
  JSON, hub `{"error"}`, MCP text/plain, Vault HTML) through a refusal hook, or accept the kit's problem+json for
  400/408/413/431/500 and record the difference?
- **Q3 (D2): streaming.** Your decision implies building it into the kit. Confirm the scope includes "start a stream
  after the handler has begun" (MCP's POST that turns into SSE). It is the part that changes `Response` the most.
- **Q4 (D3): tail capture.** Build `{name...}` (needed only by vault-mcp-web), or should vault-mcp-web change its
  URLs (for example, percent-encode `/` inside one segment)?
- **Q5: total deadline.** Hub and FleetWatch bound a whole exchange at 30 s, and the kit does not bound handlers.
  Add an optional handler deadline, or accept the difference?
- **Q6: HTTP/2 for migrated servers.** The default offers h2. The hub must pin `.http1`. Should FleetWatch (whose
  app would start negotiating h2) and vault-mcp-web start on `.http1` and turn h2 on later?
- **Q7: MCP defects.** Should the migration preserve the six behaviours in §1.4 (OPTIONS 401, the 30-minute cut,
  leaked subscription streams, the double head, the unwired header check, the CORS header list) or fix them? And
  should 401s gain `WWW-Authenticate`?
- **Q8 (D1): the clean-running period** for ijs-dashboard-server before the first migration. It is still unset.
- **Q9:** the hub on 9095: wire TLS reload now, in the hub, or wait for kit #8?
- **Q10:** should webauthn-capture migrate (a kit dependency in SwiftWebAuthn for a dev tool)?
- **Q11:** the middleware proposal in the main checkout was decided without you ("the decisions below are mine").
  Do you accept amending it for #1 (refusals reach the access log) before it lands?

---

## 8. What I did not read

- **Not read by anyone:** the live launchd plists and `hub.json` (on the host, not in git), so ports, flags and TLS
  for the MCP services rest on repo docs; swift-oauth's internals beyond `OAuthHTTPHandler` lines 40-700 and
  excerpts of `OAuthServer` (PKCE method enforcement for FleetWatch's flow, DCR redirect-URI rules, its exact error
  shapes); swift-mcp-sdk.
- **FleetWatch:** OperatorReset.swift, notifications.js, device.js, passkey.js, reset.js, most of app.js and the
  legacy scripts were grepped, not read; app.css not opened; FleetStore, FleetMonitor, Probes and other non-HTTP
  files not read; probe timeouts not read, so whether `/v1/check` fits in 30 s is unknown.
- **SwiftPushHub:** HubCLI, HubAdmin, EnrollmentDisplay, SenderRegistry, the tests, and the CHANGELOG below line 150.
- **VaultMCP:** WebRouter.swift page bodies (lines 1-99, 340-504, 581-1139), WebOptions in full, the passkey
  support files, WebAccess, and SwiftMCPServer's `AccessLogSink`/`WebAccessRecording`.
- **SwiftMCPServer:** MCPServer.swift beyond excerpts; SSESessionManager past line 258; test bodies other than the
  body-ceiling outline.
- **Others:** SSH sources (grep only); the SwiftMCPClient stub bodies; ask-the-house beyond its routes and bind.
- **Nothing was run or measured.** Keep-alive tolerance, 413 delivery against the kit, and h2 negotiation by the
  FleetWatch app are all read, not tested. The recorded exchanges in §3 are where they get tested.

**Last Updated:** 2026-10-28 (first version)
