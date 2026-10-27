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

## 3. What the kit lacks for these (decide before migrating)

| Gap | Needed by | Options |
|---|---|---|
| **Streaming responses (SSE)** | SwiftMCPServer for certain; FleetWatch not checked | Add a streaming body to `Response` and the transport; or leave MCP on its own transport |
| **Tail wildcards** (`/legacy/*`, `/enroll/*`) | FleetWatch | Register explicit routes; or add one deliberate tail-capture segment (`{path...}`) with its own rules. The kit has none on purpose, so it is a design decision, not a patch |
| **Form bodies** (`application/x-www-form-urlencoded`) | FleetWatch `/authorize` | A strict parser in the core, or the handler parses |
| **Static assets / HTML helpers** | FleetWatch | `Response.html`, `.javascript`, `.png(data:)` helpers with correct types and `nosniff`; or handlers set headers |
| **Redirects, cookies** | FleetWatch OAuth/login flow (not read) | Helpers; `Set-Cookie` attributes are easy to get wrong, so a typed builder |
| **One request per connection** | FleetWatch, Hub | The kit keeps connections alive. Check each client (a phone, a hook script) tolerates that, or add a `Connection: close` mode |
| **Per-route body limits** | Hub (64 KiB) vs the default | A per-route override on top of the global cap |

## 4. Plans, in order

Each plan keeps the package's **existing tests unchanged** as the proof, and adds a **recorded-exchange
test**: before changing anything, record every route's status, content type and body for a set of fixed
requests, then replay them against the migrated server. A difference is either intended and written down, or
a bug.

### 4.1 SwiftPushHub — first

**Why first:** its README says "bootstrapped; nothing here runs yet" (the code is 2,500 lines and the README
is stale, which is a housekeeping fix in its own right), so nothing live depends on it, and it has no
assets, forms or wildcards.
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

## 6. Decisions needed

- **D1:** the period `ijs-dashboard-server` must run cleanly before anything migrates.
- **D2:** streaming responses: build them into the kit, or keep MCP on its own transport.
- **D3:** tail wildcards: explicit routes, or one deliberate capture segment.
- **D4:** FleetWatch: migrate at all, given it works today. The case for it is one listener instead of three
  copies and the limits the kit adds; the case against is risk to a live service for no new feature.
