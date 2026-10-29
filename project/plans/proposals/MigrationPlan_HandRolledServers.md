# Migration Plan — servers that hand-roll HTTP

**Status:** proposed 2026-10-27, for the owner. **Why:** the Stack Map's `http-service` gap names a missing
kit; this repository is it. A survey of the workspace found five servers that each carry their own HTTP
listener, router and limits. The owner asked for plans to move them.

## 1. The rule: prove it first

**Nothing migrates until `ijs-dashboard-server` has served real traffic on this kit.** The transport is
unmerged and unproven, and a live service (FleetWatch is on a public port) is a poor place to find its bugs.
The first exit criterion for every plan below is: the kit's transport merged, `ijs-dashboard-server`
deployed on it on `teletran-2`, and a stated period without a transport-level fault. The owner sets the period.

## 2. What the survey found

Counts are from `grep` over each package's `Sources`; I read the files named, not every file.

| Package | Hand-rolled HTTP | Read |
|---|---|---|
| **FleetWatch** | `FleetHTTPServer` (148 lines): one request per connection, `maxConnections = 64`, a 30 s connection timeout, a body cap, TLS through `SwiftTLSKit`. `FleetRouter` (552 lines): a `switch (method, path)` with 53 literal cases, three prefix/suffix cases (`/v1/machines/*/request-report`, `/legacy/*`, `/enroll/*`), HTML/JS/CSS/PNG assets, a form `POST /authorize`, passkey routes on `SwiftWebAuthn` | listener header, route list |
| **SwiftPushHub** | `HubHTTPServer` (144 lines): the **same** shape as FleetWatch's (one request per connection, `maxConnections = 64`, 30 s timeout), loopback-only plain HTTP until "4d". `HubRouter` (232 lines) with its own `HubRequest`/`HubResponse` types, a 64 KiB body cap, bearer tokens via `swift-oauth` | listener, router header |
| **VaultMCP** (web target) | `HTTPHandler.swift` (180 lines) and `main.swift` (614 lines, with a `ServerBootstrap` inline) | file sizes, imports |
| **SwiftMCPServer** (and so `ijs-mcp-server`) | `Transport/` is about 2,200 lines. Routes are a `switch (method, path)` at `MCPServerHandler.swift:304`. Its own source says a consumer needing one more endpoint had to change the package (VaultMCP declined `POST /reindex`) | route switch, one file's header |
| `swift-sdk`, `SwiftMCPClient`, `SwiftTLSKit`, `SwiftCLIKit` | mention NIO HTTP types, but are clients, an SDK fork or TLS configuration | not read |

**The finding that matters:** FleetWatch's and SwiftPushHub's listeners are the same code with different
names. That is what the kit exists to remove.

**Already shared, correctly:** TLS. `SwiftTLSKit` (the owner's) holds identity validation, reload and the
plaintext-exposure check, and FleetWatch uses it. The kit's transport must use it too and not repeat it
(the transport worker was redirected to do so on 2026-10-27).

## 3. What the kit lacked for these (all built in 0.4.0)

| Gap | Needed by | Resolution |
|---|---|---|
| **Streaming responses (SSE)** | SwiftMCPServer | Built (D2): `Response.streaming`, `Response.eventStream`, bounded by three limits; HTTP/1.1 chunked and HTTP/2 |
| **Tail wildcards** (`/legacy/*`, `/enroll/*`) | FleetWatch | None needed (D3): every one is a single-segment parameter (`/enroll/{code}`, `/enroll/{code}/qr.png`, `/legacy/{name}`, `/v1/machines/{id}/request-report`) |
| **Form bodies** | FleetWatch `/authorize` | Built: `Request.form()`, strict |
| **Static assets / HTML helpers** | FleetWatch | Built: `Response.html/.text/.javascript/.css/.png`, with `nosniff` |
| **Redirects, cookies** | FleetWatch OAuth/login flow | Built: `Response.redirect` (no open redirects), a typed `Cookie`, `Request.cookies` |
| **One request per connection** | FleetWatch, Hub | Built: `ServiceConfiguration(connections: .closeAfterResponse)` |
| **Per-route body limits** | Hub (64 KiB) | Built: `Router.add(..., maximumBodyBytes:)`, wired by `HTTPServer(configuration:router:)` |
| Behind a proxy | the consumer's findings | Built: trusted proxies, `X-Forwarded-For` read from the right, and the PROXY protocol v1 and v2 |

## 4. Plans, in order

Each plan keeps the package's **existing tests unchanged** as the proof, and adds a **recorded-exchange
test**: before changing anything, record every route's status, content type and body for a set of fixed
requests, then replay them against the migrated server. A difference is either intended and written down, or
a bug.

### 4.1 SwiftPushHub — first

**Why first (corrected 2026-10-29):** this plan first said the README read "bootstrapped; nothing here runs yet", so
nothing live depended on it. That README was stale. SwiftPushHub is v1.0.1, shipped, with a notarized macOS Inbox and a
watchOS Inbox verified on a real Watch, public and observation intake, and 596 tests, and it **is running on Teletran 2**
(`com.roseclub.swiftpush-hub`): a live system that sends alerts to the owner's devices. It is still the right first move,
because it is the smallest of the live servers, the best tested, and its listener is the same code FleetWatch has, so
it proves the swap pattern. But it needs the full safety net (recorded exchange, run beside the old, rollback binary),
and the deploy is the owner's step.
1. Fix the README status to match the code.
2. Replace `HubHTTPServer` with the kit's transport and `HubRouter`'s `switch` with `Router`. Keep
   `HubRouter`'s handler bodies; adapt `HubRequest`/`HubResponse` to the kit's types in one file.
3. Per-route body cap (64 KiB) through the override.
4. The loopback-only rule (until TLS, "4d") becomes `SwiftTLSKit`'s `BindExposure` check, which is the same rule.
5. Verify: existing tests, the recorded exchange, and a request over a real socket.
**Risk:** low. **Done when:** the hub's tests pass unchanged, and its listener file is deleted.

### 4.2 FleetWatch — second

**Why second:** the largest payoff (53 route cases) and the best test of the router, but it is live on port
9085 and carries OAuth and passkeys.
1. Needs from §3: tail wildcards (or explicit routes), form bodies, asset helpers, redirects and cookies,
   and the keep-alive check.
2. Introduce the kit's `Request`/`Response` behind `FleetRouter` first (an adapter), changing no behaviour.
3. Move the 53 cases onto `Router` in groups: static assets, then the read API, then the OAuth endpoints,
   then passkeys. Each group ships alone, with its recorded exchange.
4. Replace `FleetHTTPServer` last, once every route is on the router.
5. Run the new server beside the old one on another port, replay the recorded exchange against both, then
   move the port forward. Keep the old binary for rollback until one full week has passed.
**Risk:** medium-high. **Done when:** `FleetHTTPServer` and the `switch` are gone and the dashboards that
poll it (FleetWatch's own web UI, the push consumers) show no change.

### 4.3 VaultMCP web target — third

**Why third:** small (794 lines) but its calendar-subscription feed is read by a calendar client "that can
only fetch over plain HTTP", which is the least tolerant client in the list.
1. Read `HTTPHandler.swift` and `main.swift` in full first; I read only their sizes and imports.
2. Same steps as 4.1. The calendar feed gets its own recorded exchange, including the headers a calendar
   client cares about (content type, caching).
**Risk:** low-medium (one fussy client).

### 4.4 SwiftMCPServer and `ijs-mcp-server` — not wholesale

The MCP transport needs streaming responses and session handling the kit does not have, and it is 2,200
lines of protocol-shaped code. Two smaller moves instead, after §3's streaming decision:
1. Its **extension routes** (`MCPHTTPRoute`, the `GET`-only list added so consumers need not change the
   package) could be registered on a kit `Router`, which also gives them parameters and a 405 with `Allow`.
2. Compare its limits with the kit's (the survey did not find the header, connection or timeout limits by
   name, which is not the same as their being absent) and adopt the stricter of each.
Replacing the transport entirely is a decision for after the kit can stream, and may never pay.

## 5. What I did not do

- Read the FleetWatch OAuth/login handlers, VaultMCP's handlers, or the whole of SwiftMCPServer's transport.
  Every "needs" above that rests on one of those is marked "not read" and must be checked first.
- Run any of these servers or measure their behaviour. Keep-alive tolerance, in particular, is untested.
- Decide the streaming, wildcard and form-body questions in §3; they need the owner.

## 6. Decisions (owner, 2026-10-29)

- **D1: two gates (option C), with FleetWatch and VaultMCP moved sooner.** The owner: those two "will be an actual
  test". Applied as: *Gate A*, SwiftPushHub, after `ijs-dashboard-server` has run a tagged 0.4.0 for about 3 days
  with no transport fault. *Gate B*, FleetWatch and VaultMCP: they start running **beside** the old server on
  another port as soon as Gate A passes (the parallel run is the test), and cut over after 7 clean days that
  include one TLS reload and one restart. 7 days is my reading of "sooner" than the 14 I proposed; the owner may
  change the number. A *fault* is a crash, a hang, a transport-made `4xx` for traffic that should have been served,
  memory or descriptor growth, a failed reload, or a shutdown that overran its grace. The access log (0.3.0) is how
  it is measured. The soaked code must be the code that migrates: 0.4.0, tagged, not the by-path build now running.
  **Gate A clock started 2026-10-29**, shortly before 23:08 UTC: `ijs-dashboard-server` was rebuilt on Teletran 2 from a
  plain clone on SwiftHTTPService **0.4.0** (revision `4889e2f`) and restarted (launchd `com.roseclub.ijs-dashboard`, new
  process 50177; it was running 0.2.0 before). Checked after the restart: the build and `check` pass; the process listens
  on 9140; an unauthenticated request to `/t/jpurnell/v1/corpora` gets `401 unauthorized` over HTTP/2 and over HTTP/1.1; the
  audit log records both; the neighbouring jobs read 0. The first `status` poll after the restart was a designed
  `503 computing` (a cold cache). The three days end about **2026-11-01 23:00 UTC**; the measure is the audit log
  (`~/ijs-dashboard/logs/audit.log`): any `5xx` other than `computing`, a change of process id, and growth in memory or
  descriptors. Rollback is `~/ijs-dashboard/ijs-dashboard-server.prev` (the 0.2.0 build).
  **Revised by the owner, 2026-10-29: Gate A is waived.** One consumer on one golden path, with a handful of requests an
  hour from the owner's own devices, gives a rare-event soak almost no chance to show anything, so a clean three days
  would be weak evidence and is not worth waiting for. Each migration instead carries its own safety net: the
  recorded-exchange replay (section 4), the new server run beside the old on another port before the cut-over, and the
  previous binary kept for rollback. The dashboard server stays on 0.4.0 and its audit log is watched passively.
- **D2: A, build streaming responses into the kit.** "We should have all of this done." The consequence is that
  SwiftMCPServer's transport can eventually move too (§4.4's "not wholesale" is revisited after streaming ships).
- **D3: A, explicit routes, no tail wildcard.** Evidence: all four FleetWatch "wildcards" are single-segment
  parameters (`/enroll/{code}`, `/enroll/{code}/qr.png`, `/legacy/{name}`, `/v1/machines/{id}/request-report`).
- **D4: A, migrate FleetWatch fully.** The owner: the kit should "cover all of our needs without having to maintain
  multiple systems". The listener and the 53 route cases both move. That makes the §3 gaps requirements, not
  options: form bodies, asset helpers, redirects and cookies, per-route limits, and a close-after-response mode.
  All of them, with streaming, the request's HTTP version, trusted proxy, and a transport refusal hook, are 0.4.0:
  `DesignProposal_0.4.0.md`.
