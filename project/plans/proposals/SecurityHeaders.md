# Design Proposal: secure-by-default response headers

**Status:** LARGELY APPROVED 2026-11-21 (owner decisions Q1, Q2, Q3, Q6 recorded in section 17; Q4, Q5, Q7, Q8 take their bracketed defaults). Reviewed against source the same day; stale proxy text, the XFO-on-HTML note, the HSTS rollback wording and the redirect-CSP test were reconciled. **Owner decision already made (2026-11-21):** every server built on SwiftHTTPService, the Hub's JSON API included, sends safe headers by default, HSTS too where that is more secure. SwiftPenTest's `HeadersChecker` goes red against a service first; this change turns it green. Target version **1.0.0-beta.5** (see section 7).

**Facts marked (repo) were read from source on 2026-11-21. Anything not checked is marked *unverified*, and every such item is in the ledger in section 18.**

**Template note:** `development-guidelines/rules/design_proposal.md` gives a 1-to-N template (Objective, Motivation, Proposed Architecture, API Surface, ...). The devguidelines MCP `get_template` was not called; the vendored `templates/` directory has no design-proposal template (only `capability_map`, `checklist`, `master_plan`, `session_summary`). This document therefore copies the section layout of the repo's newest proposals (`2026-11-21_OAuthHTTP_package.md`, `AtomicRateLimiting.md`: sections 1 to 17, Architecture Decision Review at 12, Adversarial Review at 13), with Staging and a ledger added at the end.

---

## 1. Objective

The kit writes every response in one place per protocol. Make that place add a fixed set of safe headers to every response the server sends (handler responses, 404/405, 401s a middleware makes, health, 304, HEAD, streams and SSE, and the transport's own refusals), **without overwriting anything a handler set**, and add `Strict-Transport-Security` only when the server itself is serving TLS. One explicit, named opt-out exists. Master plan: the road to 1.0.0 (`project/master_plan.md`, "Toward 1.0.0"); this is a behavior change inside the beta, which is the cheapest place to make one.

## 2. Motivation (what the source shows today)

- **No central place sets headers (repo).** `Sources/` has no `Server`, `Strict-Transport-Security`, `Content-Security-Policy`, `X-Frame-Options` or `Referrer-Policy` anywhere (grep). `X-Content-Type-Options: nosniff` is set only by the *typed* helpers `Response.html/text/javascript/css/png` (`ResponseHelpers.swift`, private `typed`). **`Response.json`, `Response.problem`, `Router.addHealth`, `Response.eventStream` and the transport's `Refusal.response` do not set it** (`Response.swift`, `Health.swift`, `EventStream.swift`, `SharedRules.swift`). So the JSON API, which is the Hub's whole surface, is the part that lacks it.
- **`Cache-Control` is set by hand in each consumer (repo):** `SwiftDiagnosticsHub/.../HubReadAPI.swift:183`, `ijs-dashboard-server/.../Routes.swift:94,304` and `PasskeyRoutes.swift:191`. `Response.eventStream` sets `no-store` itself. SwiftPushHub's sources contain no `Cache-Control`, `nosniff` or `Strict-Transport` (grep over its `Sources`, no match; this agrees with SwiftPenTest's `Phase2-Checkers.md` section 5.3).
- **Server version leakage: none today (repo).** The transport writes `Date`, `Connection`, `Content-Length` (and `Keep-Alive`/`Transfer-Encoding` are stripped, `ResponseRules.prepare`). No `Server` header is added by the kit; NIOHTTP1 and the NIO HTTP/2 codec add none that the kit's code shows. *Unverified at the byte level:* the pin in the tests below is what verifies it.
- **FleetWatch already has a header set** (repo, `FleetRouter.swift:73-79`: CSP, nosniff, `Referrer-Policy: no-referrer`, `Strict-Transport-Security: max-age=31536000`), and VaultMCP's `PageLayout.headers` has CSP, `Cache-Control: no-store`, nosniff, XFO (repo grep, `PageLayout.swift:45-48`). The two servers that do this well each hand-rolled it; the kit's other three consumers did not. That is the case for putting the default in the kit.

## 3. Proposed Architecture

### 3.1 Where the headers are added (the one place)

Every write site funnels through `ResponseRules.prepare(_:)` (repo, `SharedRules.swift`), which already strips the transport-owned fields. The call sites (repo grep): `ConnectionHandler.write` and `.writeStreaming`, `StreamHandler.write` and its streaming twin (HTTP/2), `BusyRefusalHandler` (plaintext busy 503), `BusyStreamHandler` (HTTP/2 busy 503). The transport's own refusals (`refuse(...)`, 400/408/413/417/431/500/503/505) go through `ServerContext.response(for:)` and then the same `prepare`. So adding the policy inside `prepare` covers **handler results, router 404/405, middleware 401/429, thrown errors (the 500 refusal), health, 304, HEAD, streaming head, SSE, busy refusals, HTTP/1.1 and HTTP/2** with no per-route code.

- **Change:** `ResponseRules.prepare(_ response: Response, policy: ResponseHeaderPolicy, overTLS: Bool)`. The old one-argument signature is **removed**, so a missed call site is a compile error, not a gap. `ServerContext` gains `let headerPolicy: ResponseHeaderPolicy` and `var overTLS: Bool { configuration.tls != nil }` and the six call sites pass them.
- **Why in the transport and not only a `Middleware`:** a middleware never sees the transport's own refusals, the busy refusals, or the 500 made from a thrown error (those are written without calling the handler or after it threw; `ResponseRules.outcome(of:)`). The checker will probe error paths. A middleware-only design would leave exactly those red.
- **Also exposed as a pure function** `ResponseHeaderPolicy.applying(to:overTLS:) -> Response` in the core module (`SwiftHTTPService`), so it is unit-testable with no NIO and usable by a hand-rolled server (VaultMCP, SwiftMCPServer) that wants the same defaults without the kit's transport.

### 3.2 Merge rule

1. **A handler's explicit value always wins** (set only if the field is absent, compared case-insensitively; `HTTPFields` already does this). This is what makes the change behavior-compatible for FleetWatch's CSP and HSTS, the Hub's `no-store`, ijs's `no-store`, a static asset's `Cache-Control: no-cache`.
2. No header is ever added twice; `Vary` is never touched (so `cors()`'s `Vary: Origin` is unaffected).
3. Applied to every status including 1xx-excluded 204 and 304, and to HEAD (headers describe the would-be GET; the body is dropped by the transport as today).

### 3.3 Files

**New (core):** `Sources/SwiftHTTPService/ResponseHeaderPolicy.swift`.
**Modified (core):** `ServiceConfiguration.swift` (carry the policy; see 4.3).
**Modified (transport):** `SharedRules.swift` (`prepare`), `ServerContext.swift`, `ConnectionHandler.swift`, `StreamHandler.swift`, `BusyRefusalHandler.swift`, `BusyStreamHandler.swift` (pass the two values; no logic).
**Docs:** README (new "Response headers" section and status), CHANGELOG, `master_plan.md`.

## 4. API Surface (sketch, not a commitment)

```swift
public struct ResponseHeaderPolicy: Sendable, Equatable {
    /// Added to every response that lacks the field.
    public var always: HTTPFields
    /// Added only to a response whose body is JSON (`application/json`, `+json`, including problem+json) or empty.
    public var apiOnly: HTTPFields
    public var hsts: HSTS
    /// Non-nil only for `.disabled(because:)`; log it when the server starts.
    public var optOutReason: String? { get }

    public static let secure: ResponseHeaderPolicy          // the default
    public static func disabled(because reason: String) throws(ConfigurationError) -> ResponseHeaderPolicy
    public func applying(to response: Response, overTLS: Bool) -> Response

    public enum HSTS: Sendable, Equatable {
        /// Sent only when the server itself serves TLS (`ServiceConfiguration.tls != nil`). Default, 7 days.
        case whenServingTLS(maxAge: Duration)
        case off
    }
}
```

### 4.1 The default set (`.secure`) and why each value

| Header | Value | Added to | Reason |
|---|---|---|---|
| `X-Content-Type-Options` | `nosniff` | every response | Closes the gap that `json`, `problem`, health, SSE and refusals lack it today. |
| `Cache-Control` | `no-store` | every response, if absent | The kit is "a small JSON API" (`Limits` doc); responses can hold per-user data. Matches what Hub, ijs, VaultMCP and `eventStream` already say. See the cost in 13. |
| `Referrer-Policy` | `no-referrer` | every response | Free; FleetWatch and VaultMCP already send it. |
| `X-Frame-Options` | `DENY` | every response | Legacy twin of `frame-ancestors`; what VaultMCP's page contract and OWASP's REST list use; scanners look for it. |
| `Content-Security-Policy` | `default-src 'none'; frame-ancestors 'none'` | **JSON and empty responses only** | The standard API CSP. **Not** applied to `text/html` and other types: the kit cannot know what a page loads, and `default-src 'none'` on a handler's HTML page that lacks its own CSP would blank it. HTML servers set their own (FleetWatch, VaultMCP do). |
| `Strict-Transport-Security` | `max-age=604800` (7 days), nothing else | only when `overTLS` | See section 6. |
| `Content-Type` | **not defaulted** | n/a | The kit cannot guess; `json`, `problem`, `html`, `text` and refusals already set it. A body-bearing response without one is a handler bug the checker should flag, not something to mask with a made-up type. A test pins that every kit-built response has one. |
| `Server`, `X-Powered-By` | not sent; **not stripped** | n/a | Nothing to strip today. A test pins their absence on every path. Stripping a handler's own value would be a second mechanism for no present case. |

**Considered and left out of the default:** `Permissions-Policy`, `Cross-Origin-Opener-Policy`, `Cross-Origin-Embedder-Policy` (browser-feature headers, nothing to protect on a JSON API); `Cross-Origin-Resource-Policy: same-origin` (could interfere with `no-cors` embedding by a consumer; revisit once the owner states whether any API is meant to be embedded); `includeSubDomains` and `preload` (not representable in this release, 6).

### 4.2 Per-route and per-service override

- **Per route:** a handler (or a route's `middleware:`) sets the header itself; rule 3.2.1 makes it win. That covers caching (`Cache-Control: max-age=...`), a page's own CSP, a route that must be framed. Removing a default per route (e.g. no `nosniff`) is **not supported**: no case in the workspace wants it, and an omit sentinel on `Response` would add a public stored property and an initialiser. Open question 4.
- **Per service:** the `ResponseHeaderPolicy` passed in the configuration. Variants are built by mutating `always`/`apiOnly`/`hsts` on `.secure` (a service that wants `Cache-Control: private, max-age=60` as its default).
- **Opt-out:** `ResponseHeaderPolicy.disabled(because:)`. It is by name, requires a non-blank reason (throws `ConfigurationError` field `responseHeaders.reason`, `.empty`), and exposes `optOutReason`. **"Logged" is honest only in this form:** the kit has no logging facility (repo: no `Logger`, no `print` outside doc comments; the access log is a caller-supplied sink), so the kit cannot log by itself. The server exposes `HTTPServer.responseHeaderPolicy`; the consumer prints `optOutReason` at start (the Hub already prints startup lines, e.g. `HubServer.swift:204`). The opt-out is *also* visible from outside because the checker goes red. Open question 5 asks whether to add a `startupNotes` hook like `RefusalHooks`.

### 4.3 Carrying the policy: the compatibility hazard

`ServiceConfiguration` is the natural carrier (it already has `tls`, which HSTS needs) but its public `init` is called by four consumers with labelled arguments, and CI runs `swift package diagnose-api-breaking-changes` (repo, master plan; baseline in `API_BASELINE`). Adding a parameter to a public initialiser **removes the old signature, which the digester will report**, even if every call site still compiles. Choose in this order, stopping at the first that passes the digester:

1. Add a stored `public let responseHeaders: ResponseHeaderPolicy` and a **second `init` overload** with the extra trailing defaulted parameter, keeping the original `init` (which sets `.secure`). *Unverified:* that a call omitting the new argument resolves to the old overload without ambiguity (Swift normally prefers the overload needing fewer defaults); verify by compiling the four consumers' call sites in the first TDD step.
2. If ambiguous: a `public var responseHeaders` (default `.secure`) set after the throwing init. Uglier, certainly non-breaking.
3. Fallback: a new parameter on both `HTTPServer.init`s, with the same overload trick.

Equatable synthesis on `ServiceConfiguration` is unaffected (the policy is Equatable).

## 5. MCP Schema

Not applicable: an in-process Swift API, no tool surface.

## 6. HSTS: when, how, and the operational risks

### 6.1 When it may be sent

- **Only over TLS, never over plaintext.** A browser ignores HSTS received over HTTP (RFC 6797 section 8.1; *from memory, unverified against the text*), so sending it is useless and a scanner flags it. The server knows which it is serving: `configuration.tls` is nil (plaintext HTTP/1.1; HTTP/2 is only negotiated over TLS, repo `Protocols` doc) or non-nil (every connection is a TLS connection; there is no mixed listener in `HTTPServer`, repo). `overTLS = tls != nil` is therefore a per-server constant, correct for HTTP/1.1, HTTP/2, busy refusals over TLS, and TLS reload.
- **No current service is behind a TLS terminator (traced 2026-11-21, see "Observed baseline").** Every listener on Chromedome and Teletran 2 answered a TLS handshake itself (TLS 1.3, one Python service on 1.2); no proxy process runs on either host; the one relay, `socat TCP-LISTEN:9095 -> TCP:192.168.1.2:9095`, is a plain TCP forward, so TLS still ends in the Hub. An earlier draft of this section took `trustedProxies`/`forwarding: .xForwardedFor` (`SwiftDiagnosticsHub/.../HubServerConfiguration.swift:216`) as evidence of a proxy; that line is conditional (`trustedProxies.isEmpty ? .none : .xForwardedFor`), the list defaults to empty, and `HubTLS.md` records that the deployed configuration drops it. The kit does not read `X-Forwarded-Proto` (repo grep: no match). `alwaysAssertingTLSUpstream` therefore has no current user.

### 6.2 The value, and why it is modest

`max-age=604800` (7 days), no `includeSubDomains`, no `preload`. Reasons:

- A browser remembers it for max-age seconds and the only revocation is a TLS response with `max-age=0` that the browser must revisit. A short initial value bounds the worst case at a week. FleetWatch already ships a year (repo) and, by rule 3.2.1, keeps it.
- **`includeSubDomains` and `preload` are not representable** in `HSTS` in this release. Adding them later is additive; removing a preload entry takes months. (This is the owner's draft position and I agree.)
- The ramp is a config change, not a code change: 7 days, then 30, then 180 once the owner has seen nothing break. Mozilla-style scanners want 6 months, so a low initial value will show as a weak score on the checker; the checker threshold in section 9 is set to accept the default.

### 6.3 Operational risks, by how a host is reached

| Reached by | Effect | Risk |
|---|---|---|
| **IP address** (e.g. `https://10.0.1.114:9080`) | RFC 6797 says a user agent must not note HSTS for an IP host (*from memory, unverified*). Harmless; no protection either. | None. |
| **`.local` name** (`chromedome.local`) | Honored by browsers like any host name, but **HSTS is per host, not per port**: a browser that has once seen the header from `https://chromedome.local:9080` will then rewrite `http://chromedome.local:<other port>` to https. Chromedome and Teletran 2 run several services on different ports (CLAUDE.md; SwiftPenTest `Phase2-Checkers.md` section 5.4 lists 9080 to 9089), some of which are plaintext. **This is the real hazard of this change on this estate.** | A plaintext sibling service on the same hostname becomes unreachable *in that browser* until max-age lapses. Mitigation: 7-day cap; per-host audit before enabling HSTS on a host that also serves plaintext (open question 3); or `.off` on the TLS service on such a host. |
| **A private CA / self-signed cert** | A browser only records HSTS from a connection with a valid cert chain, and with HSTS active it removes the click-through. A cert that later lapses locks the user out hard. | Medium for `.local` services; the SwiftTLSKit reload work reduces expiry risk but does not remove it. |
| **Non-browser clients** (curl, SwiftPush app, MCP clients, the checker) | Ignore the header (curl only with `--hsts`; *URLSession's behavior unverified*). | None operationally; little security value, which is why HSTS is a browser feature and why `Phase2-Checkers.md` section 5.3 wanted it to be `info`. |
| **Several hostnames for one service** (SwiftPushHub's `hostnames:`, repo `HubHTTPServer.swift:71`) | The header applies to whichever name the client used. | Low. |

The owner's instruction was "HSTS too, if that is more secure". It is more secure for browser-reachable TLS endpoints (FleetWatch's pages, the VaultMCP-style UIs). For a JSON API consumed only by apps it adds almost nothing and carries the per-host risk above. The default of "automatic when the server serves TLS" accepts that cost; the escape is `.off`. I recommend it, with the caveat in open question 3.

## 7. Source & API compatibility; version and CHANGELOG

**Repo state (verified):** local `main` is `5ad5e82` = tag `v1.0.0-beta.3` and is **4 commits behind `origin/main`**, which holds `v1.0.0-beta.4` (`8c3dc82`) and two later commits (`155c1a7` CI, `3b7b5b6` docs). All four dependents pin `exact: "1.0.0-beta.4"` (repo, their `Package.swift`). **First step of implementation: `git pull`**, and use beta.4 as the API baseline (CI's `API_BASELINE` moves to beta.4 upstream).

**README claim** (`README.md:5`): "1.0.0-beta.3 (2026-11-13) ... the API is frozen for the 1.0 line pending the beta." (It is stale vs beta.4; the reconcile step updates it.)

**Verdict, stated precisely:**
- **Source-compatible: yes, if 4.3 passes the digester.** All changes are additive types and an additive init path. The `diagnose-api-breaking-changes` step (CI) is the check; run it locally before the first commit. If it flags the initialiser, use fallback 2.
- **Behavior-compatible: no, and this must be said plainly.** Defaults-on changes bytes on the wire for every consumer. What changes for an unmodified handler: it gains `nosniff`, `Cache-Control: no-store` (if it set none), `Referrer-Policy`, `X-Frame-Options`, a JSON-only CSP, and HSTS if it serves TLS. Concrete cases from the repo:
  - Handlers using `Response.html/css/png` with `cacheControl: nil` become `no-store` (e.g. FleetWatch `/notifications`, `FleetRoutes.swift:101`). They stay cacheable if they pass a `cacheControl` (FleetWatch's css/icons do).
  - `Conditional.respond` (ETag, 304) builds the 304 with only an `ETag` (repo, `Conditional.swift`); with `no-store` added, a client may not *store* the body it later revalidates. The Hub sets `no-store` itself and also returns ETags today, so the combination is already shipping.
  - HSTS appears on every TLS-serving consumer that did not set it.
  - **`X-Frame-Options: DENY` applies to HTML too** (unlike the CSP, which is JSON/empty only). A consumer that frames its own pages (check ijs's passkey pages; FleetWatch sets no XFO today) would break until it sets its own value, which wins by 3.2.1. The CHANGELOG must say so.
  - **A 301/302 redirect has an empty body, so it gets the JSON CSP.** Harmless; pinned by a test so it is deliberate.
- A frozen-API promise covers signatures; it does not promise stable response bytes (the CHANGELOG has shipped behavior fixes inside the beta before, e.g. beta.2 X-Forwarded-For). **Verdict: a source-compatible, behavior-changing release; ship it as a beta bump, not a patch to a stable 1.0.0.** After 1.0.0 the same change would be a minor release.

**Version:** `1.0.0-beta.5`. **CHANGELOG:** a `### Changed (behavior)` entry listing the defaults and the table above, an `### Added` entry for `ResponseHeaderPolicy`, the opt-out and how to ramp HSTS; update the link-reference definitions at the bottom (CLAUDE.md Doc Housekeeping); README status and a "Response headers" section; `master_plan.md` Last Updated and a checked item.

## 8. Storage

None. The policy is immutable configuration read per response.

## 9. What SwiftPenTest's `HeadersChecker` asserts (so the two proposals agree)

Source: `SwiftPenTest/project/plans/proposals/Phase2-Checkers.md` section 5.3 (read) and open question 3 at section 17. That text currently says **HSTS on the hub is `info` until the owner decides**, and expectations come from each server's source. This proposal supplies the source, so the checker's expectation for a **kit-based JSON target** becomes the table below. Please apply the same table to section 5.3 (checker proposal is not edited here).

| Assertion on every probed response (200, 401, 404, 405, 413/431 if probeable, health) | Value |
|---|---|
| `X-Content-Type-Options` | exactly `nosniff` |
| `Cache-Control` | contains token `no-store` (token match, not string equality: a service may add `, private`) |
| `Content-Type` | present on a bodied response; `application/json` or `application/problem+json` for the API (parameters ignored) |
| `Content-Security-Policy` | parsed structurally: `default-src` is `'none'` and `frame-ancestors` is `'none'` |
| `X-Frame-Options` | `DENY` |
| `Referrer-Policy` | `no-referrer` |
| `Server`, `X-Powered-By` | absent, or no version-like token (`/\d`) |
| `Strict-Transport-Security` over **HTTPS** | present, `max-age` >= 86400 (below the 604800 default so the first release is green, and so a later increase never goes red); no `preload` assertion either way |
| `Strict-Transport-Security` over **plain HTTP** | must be **absent** (HSTS over plaintext is useless and a scanner flags it; the kit sends it only when it serves TLS itself) |

Two checker-side notes: (a) change HSTS from `info` to `failed` for HTTPS targets (decided, open question 1); (b) the checker must probe the *public* endpoint; no current service has a terminator in front (see "Observed baseline"), so a missing HSTS is the service's own, not a proxy's.

## 10. Resource Budget

Per response: one pass over at most about six fields and a media-type check, on the connection's event loop, allocation of one `HTTPFields` copy already made by `prepare`. Negligible next to encoding the body. Response size grows by about 250 bytes per response (nosniff 40, no-store 24, referrer 30, XFO 22, CSP ~60, HSTS ~45); on HTTP/2 HPACK compresses the repeats. *Unverified by measurement;* not worth a benchmark unless the Hub's ingest path is header-bandwidth-bound, which nothing says.

## 11. Test Strategy (red first; no real network)

All tests use what the repo already has: pure core tests, `ResponseRules` via `@testable`, and the embedded-channel harness (`PipelineHarness` with `NIOAsyncTestingChannel`, `WireResponse` parsing raw bytes, `DirectHandlerTests`). **No loopback socket is required for any of these;** the existing `...OverTheWire` suites show the pattern if one smoke test is wanted, but it is optional.

1. **Policy, pure (`SwiftHTTPServiceTests/ResponseHeaderPolicyTests`):** each default added to a bare `Response`; a handler's `Cache-Control`, CSP, HSTS are never replaced (and not duplicated); case-insensitive match (`cache-control`); API CSP added to `application/json`, `application/problem+json`, `application/vnd.x+json`, and an empty body, **not** to `text/html`, `text/event-stream`, `image/png`; a 302 with an empty body does get it (pinned); `X-Frame-Options: DENY` is added to `text/html` too; HSTS absent when `overTLS == false`, present with `max-age=604800` when true, `.off` removes it; the `HSTS` type cannot express `includeSubDomains`/`preload` (a test over the rendered value); `disabled(because:)` with blank reason throws `.empty` and the policy then adds nothing; `Equatable`.
2. **Every response path carries the headers (`SwiftHTTPServiceNIOTests/SecurityHeadersEveryPathTests`).** One parameterised test over this list, asserting the full table of 4.1 on each, on HTTP/1.1 and (embedded H2 frames) HTTP/2:
   - handler `200` (`Response.json`), `Response.problem`, `Response.empty(.noContent)`, `304` via `Conditional`, `HEAD`;
   - router `404` (default `notFound`) and `405` (default `methodNotAllowed`), **and a custom `notFound`/`methodNotAllowed`** that returns a bare `Response`;
   - a middleware `401` and `429` (`rateLimit`), and `403` from `allowedHosts`;
   - the health route (`addHealth`);
   - a **thrown error** (handler throws; the 500 refusal);
   - **every case of `Refusal.allCases`** (it is `CaseIterable`, repo `Refusal.swift`) through `server.response(for:)` then `prepare`, so a new refusal added later is covered automatically;
   - the busy refusal, plaintext (`BusyRefusalHandler`) and HTTP/2 (`BusyStreamHandler`);
   - a streaming response (`Response.streaming`) and `Response.eventStream`: the **head** carries the headers (asserted before the first body byte); the SSE head has exactly one `Cache-Control` and it is the helper's own `no-store`.
3. **Completeness by construction:** because the old `prepare(_:)` signature is deleted, a test cannot be the only guard; a compile of the transport target is. Add one extra assertion: a test that scans `Sources/SwiftHTTPServiceNIO/*.swift` is **not** proposed (brittle, and compile enforcement is stronger).
4. **TLS knowledge:** a `ServerContext` built with `tls:` non-nil emits HSTS on every path in 2, and with `tls: nil` emits none on every path. (Uses `ServiceConfiguration(tls: TLSFiles(...))` with dummy paths; the configuration only stores paths, repo, and the embedded harness never handshakes, so no certificate is needed. *Unverified that the harness accepts a TLS-configured context without opening files; if not, test `overTLS` as a pure `ServerContext` property and the policy in test 1.*)
5. **Version-leak pin:** on every path in 2, no `Server` or `X-Powered-By` field, and no field value contains `NIO` or the kit's version string.
6. **Hub-shaped regression:** the Hub's `respond` closure (`no-store` + `ETag`) produces exactly one `Cache-Control`, equal to the Hub's own.
7. **Compile check of consumers' call sites:** a test file in the kit that builds `ServiceConfiguration` using the exact argument lists the four consumers use (`HubServerConfiguration.swift:215`, `HubHTTPServer.swift:130`), to catch overload ambiguity (4.3).
8. Existing suites must pass **untouched**, except any that assert an exact header set on a response (*unverified which; the first red run will list them*, and each is updated by adding the new headers to its expectation, not by weakening it).

## 12. Architecture Decision Review

- **One place.** The decision between *middleware*, *a `Response` helper*, and *the transport's `prepare`* is the transport, for coverage of error and refusal paths (3.1). The policy value lives in the core so the logic is testable without NIO, matching how `cors`, `allowedHosts`, `rateLimit` and `accessLog` are core values and the transport only wires (`DesignProposal_Middleware.md`).
- **Order with other layers:** the policy runs after all middleware (including `cors`, `requestID`, `accessLog`), so those see the handler's response without the defaults. Consequence: `accessLog` records status and bytes only (repo: never headers), so it is unaffected.
- **Concurrency:** `ResponseHeaderPolicy` is an immutable `Sendable` value; `ServerContext` is already `Sendable` and never mutated; no new actor, no `@unchecked Sendable`, no locks.
- **No new dependency;** no new module. `HTTPTypes` is already imported by both modules.
- **Quality gate:** no force unwraps (field names built with `HTTPField.Name(...)` behind a guard or a `static let` as `SafetyHeader.noSniff` does; note that one uses `preconditionFailure`, which an auditor may dislike: use the `HTTPField.Name` built-in constants where they exist (`.cacheControl`, `.strictTransportSecurity`, `.contentSecurityPolicy`, `.referrerPolicy`, `.xFrameOptions`) and for the rest follow the existing pattern *unverified for which constants swift-http-types ships*), no suppression annotations, DocC on every public symbol.

## 13. Adversarial Review

**The strongest alternative: leave headers to a reverse proxy, or make them opt-in.**

*The case against my default.* (a) HSTS is a property of the TLS endpoint the browser sees, and a kit behind a terminator would send it in the wrong place. *Rejected 2026-11-21 as a present concern:* the topology trace (6.1) found no service behind a terminator, and the design sends HSTS only when the kit itself serves TLS. (b) The estate already has the headers where they matter, hand-rolled in the two HTML servers, and the JSON API consumers are non-browser, so most of this buys little. (c) Default `no-store` is a real behavior change that costs bandwidth and defeats the ETag/304 path the kit itself ships (`Conditional`). (d) A kit default that edits responses is something every future consumer must discover; a proxy config is explicit and reviewable (`roseclub-ops`). (e) The checker can enforce on the proxy's output regardless.

*Why I still recommend default-on:* (1) the owner decided it, and the red-then-green workflow needs a place that produces green; (2) the proxy is not universal: the Hub's and SwiftPushHub's configurations take `tls: TLSFiles` and serve TLS themselves (repo), and `ijs-dashboard-server`/FleetWatch are directly exposed ports; "leave it to the proxy" leaves those bare, and `ijs`, `FleetWatch`'s mixed state shows hand-rolling drifts (FleetWatch's `securityHeaders` has no `X-Frame-Options`, the Hub's JSON has none of them); (3) the headers I make default are the ones with no legitimate reason to be absent on a JSON API; (4) "set if absent" keeps every deliberate choice; (5) HSTS is the only one that depends on the transport, and the design refuses to guess: it follows `tls != nil` or an explicit assertion.
*What I concede and have bounded:* (c) is the weakest point, see open question 2: if the owner prefers, drop `Cache-Control` from `always` and apply `no-store` only to responses that carry an `Authorization`-dependent or non-GET result; I recommend keeping it, because the kit has no knowledge of which GETs are per-user. (a) is why HSTS is sent only when the kit itself serves TLS and never inferred from a forwarded header (a mode that asserts TLS upstream was dropped by the owner on 2026-11-21).

**Other attacks on this design:**
- **HSTS lock-out on a shared hostname** (6.3): real, bounded by 7 days, can be turned off; needs a per-host audit before rollout, not a code fix.
- **Default CSP breaking a page:** avoided by applying it only to JSON and empty responses. Residual: a handler that returns `application/json` that a browser renders in a framed context needing script: none known.
- **Duplicate or conflicting headers:** set-if-absent plus `HTTPFields` subscript replacement; the Hub test (11.6) pins it.
- **Header injection:** values are constants; no request data reaches a field (test 5 plus review: the policy has no request parameter).
- **A new transport path added later that forgets the policy:** compile-enforced by removing the old `prepare` signature (3.1), and every `Refusal` case is enumerated in test 2.
- **HEAD/304/204 carrying CSP and HSTS:** allowed by the specs and harmless; chosen so a scanner that HEADs the endpoint sees them.
- **HSTS over plaintext:** not possible: the only modes are `whenServingTLS` and `off`. A mode that asserts TLS upstream was designed, then dropped by the owner on 2026-11-21 because no current service has a terminator in front (section 6.1); it can be added later as an additive case.
- **Mis-sells security:** these headers harden browsers and do nothing against a non-browser attacker; the proposal's claim is conformity and defense in depth, not that the API is safer. Do not let a green checker be read as more than that.

## 14. Alternatives Considered

- **Opt-in per service** (policy default `.none`): rejected by the owner's decision and because "off by default" is how the Hub ended up with none; kept as `.disabled(because:)`.
- **Middleware only:** rejected, misses refusals and thrown-error 500s (3.1). A middleware form can still be added later by wrapping `applying(to:overTLS:)`, which is why that function is public.
- **`Response.json` and friends add the headers themselves:** rejected, misses router 404/405, middleware 401/429, thrown-error 500, health, refusals, and every hand-built `Response`.
- **Per-route omit sentinel on `Response`:** rejected for v1 (4.2).
- **Believe `X-Forwarded-Proto` to decide HSTS:** rejected (6.1).
- **Include `includeSubDomains`/`preload`:** rejected (6.2).
- **A long HSTS default (1 year, as FleetWatch has):** rejected for the first release; the ramp is configuration.
- **Strip a handler's `Server`/`X-Powered-By`:** rejected, nothing sets them.

## 15. Future Directions

- A second stage: raise the HSTS default to 30 and then 180 days after a clean soak; consider `includeSubDomains` only per owner decision for a named domain with an audit of every subdomain.
- A Hub-facing `Cross-Origin-Resource-Policy` and `Permissions-Policy` set if a browser-facing Hub UI appears.
- Offer `ResponseHeaderPolicy.applying` to VaultMCP and SwiftMCPServer (outside the kit; section 16.2).

## 16. Coverage: who gets this, and who does not

### 16.1 Covered (depends on the kit; repo, `Package.swift` grep across `Tools/`)

| Server | Pin | Serves TLS itself? | Notes |
|---|---|---|---|
| **SwiftDiagnosticsHub** | exact `1.0.0-beta.4` | optional `tls: TLSFiles?`; serves its own TLS in production (probed 2026-11-21); `trustedProxies` defaults empty and the deployed config drops it | JSON API; `HubReadAPI` already sets `no-store`; `protocols: .http1`, `.closeAfterResponse`. *Production TLS topology unverified.* |
| **SwiftPushHub** | exact `1.0.0-beta.4` | `tls: files` in `HubRuntime.swift:152` | JSON router; sets none of the headers (grep) |
| **ijs-dashboard-server** | exact `1.0.0-beta.4` | *unverified* | sets `no-store` per route; serves passkey pages; deployed on Teletran 2 (master plan) |
| **FleetWatch** | exact `1.0.0-beta.4` | *unverified* | **HTML-heavy; already sets its own CSP, nosniff, Referrer-Policy, HSTS 1 year, on every response (`FleetRouter.securityHeaders`).** Should see little change; most at risk of surprise because of pages and caching |

(The dependents were matched by `grep -l "SwiftHTTPService" */Package.swift` over `Tools/`: FleetWatch, ijs-dashboard-server, SwiftDiagnosticsHub, SwiftPushHub. The `.claude/worktrees/` copy inside this repo is not a dependent.)

### 16.2 Not covered (do not claim them)

- **VaultMCP web** (`Sources/VaultMCPWebMain/HTTPHandler.swift`, `main.swift`, `ServerBootstrap`; `Package.swift` shows NIO, no SwiftHTTPService). Serves HTML with its own `PageLayout.headers` (CSP, `Referrer-Policy`, `Cache-Control: no-store`, nosniff, XFO); **no HSTS found** (grep). Also `AskTheHouse` and `CalendarFeed` (own `Cache-Control: no-store`, `X-Robots-Tag`). The JSON-API defaults are **wrong** for its HTML pages (CSP in particular), which is why `PageLayout` has its own; the checker's expectation for it comes from `PageLayout.headers` per `Phase2-Checkers.md`. *Not read beyond grep.*
- **SwiftMCPServer** (NIOHTTP1 `MCPServerHandler`, `HTTPResponseManager`, SSE with `Cache-Control: no-cache`, `HTTPAuthentication`). Its SSE uses `no-cache`, which this default (`no-store`) would have changed; irrelevant, since it is not on the kit. *Not read beyond grep.*
- **Libraries and clients** that mention NIO but serve nothing: `swift-oauth`, `SwiftWebAuthn`, `SwiftMCPClient`, `swift-sdk`, `SwiftTLSKit`, `SwiftCLIKit`, `swift-cli-kit-auth`, `SwiftPenTest` itself.
- Anything else outside `Tools/` (not searched).

So **four of the six HTTP servers I found are covered** (the four above, plus VaultMCP web and SwiftMCPServer, which are not; others outside `Tools/` unsearched); VaultMCP and SwiftMCPServer, "deferred on purpose" in the master plan, are not, and a green checker on them depends on their own code (or a later migration, or calling `ResponseHeaderPolicy.applying` from their handler, which is a small add if the owner wants it).

## 17. Open Questions (the owner's calls)

**Decided by the owner, 2026-11-21** (answers to the numbered questions below; the owner replied "ok" / "yes"):

- **Q1, HSTS default: accepted.** Automatic when the server serves TLS, 7 days, no `includeSubDomains`/`preload`. SwiftPenTest's `HeadersChecker` promotes missing HSTS from `info` to `failed` for HTTPS targets.
- **Q2, `Cache-Control: no-store`: always on.** The loss of the kit's ETag/304 benefit is accepted.
- **Q3, per-host audit before HSTS: required, and done for the plaintext-sibling hazard (2026-11-21).** No non-loopback port on either host serves plaintext; every one answered TLS, so the per-host HSTS hazard of breaking `http://` siblings does not occur today. What remains is the lapsed-certificate lock-out (the certificate runs to 2027-01-15; `CertWatch` watches it) and the ports that cannot send HSTS today (see the baseline table).
- **Q6, behind a proxy: `alwaysAssertingTLSUpstream` DROPPED by the owner, 2026-11-21.** The topology trace found no service behind a TLS terminator (section 6.1, "Observed baseline"). HSTS has two modes, `whenServingTLS` (default) and `off`. If a terminator is ever put in front, add the explicit mode as an additive case then; until then the checker's "no HSTS over plaintext" assertion holds for every target.
- **Still open (none blocks implementation; defaults in brackets are what gets built unless the owner says otherwise):** Q4 (omit mechanism) [none: handler's own value wins], Q5 (opt-out logging) [`optOutReason` exposed, consumer logs], Q7 (VaultMCP and SwiftMCPServer) [out of scope], Q8 (Cross-Origin-Resource-Policy) [not added].

Q1, Q2, Q3 and Q6 were decided above and are removed from this list.

4. **Per-route removal of a default:** is "handler sets its own value" enough, or is an omit mechanism wanted (it adds a public `Response` member)?
5. **Opt-out logging:** is "the server exposes `optOutReason`, the consumer logs it" enough, or add a `startupNotes` hook beside `RefusalHooks` (a small additive API)?
7. **VaultMCP and SwiftMCPServer:** leave as is (their own headers), or add HSTS and the missing pieces there as a separate change?
8. **Cross-Origin-Resource-Policy:** wanted on the JSON API?

## 18. Ledger: what I could not verify (guesses are marked unverified above)

1. RFC 6797 behavior (ignored over HTTP, not noted for IP hosts, hard-fail on cert errors, per-host not per-port): from memory, not re-read. The estate-specific port-sharing hazard follows from it.
2. Whether URLSession (the SwiftPush app, other Apple clients) honors HSTS: not checked.
3. ~~Which production services terminate TLS themselves vs behind HAProxy~~ **Resolved 2026-11-21** by probing every listener on both hosts: all terminate their own TLS; no proxy runs; `socat` on Chromedome is a plain TCP relay for 9095. Not resolved: what the router forwards, and reachability from outside (probed from the LAN only).
4. ~~Whether `ijs-dashboard-server` and FleetWatch pass `tls:` to the kit~~ **Resolved 2026-11-21:** both listeners answer TLS (FleetWatch 9085, ijs-dashboard 9140, which negotiated HTTP/2).
5. Swift overload resolution for the extra `ServiceConfiguration.init` overload and the digester's verdict: not compiled (no code was to be written). The fallback is in 4.3.
6. Which existing tests assert an exact response header set and will go red: not enumerated.
7. Whether the embedded harness accepts a TLS-configured `ServerContext` without file access (test 11.4): not checked.
8. Which `HTTPField.Name` constants swift-http-types ships (`strictTransportSecurity`, `contentSecurityPolicy`, `xFrameOptions`, `referrerPolicy`): not checked.
9. That NIOHTTP1 and the NIO HTTP/2 codec add no `Server` header: inferred from the kit's code, to be pinned by test 11.5.
10. VaultMCP and SwiftMCPServer: read by grep only; their dependency on the kit is "none" from `Package.swift`, nothing more.
11. FleetWatch's `securityHeaders` being applied to every response (the doc comment says so); whether the HSTS is conditional on TLS: not read past the declaration.
12. SwiftPenTest's `HTTPProbe` shape and the checker's current code: only the proposal was read, not the sources.
13. Local `main` is behind `origin/main` by 4 commits; I read the local tree plus `git log` of the remote, not the remote's file contents. The beta.4 source delta is documented as "SwiftTLSKit 1.0.0, no source change" (CHANGELOG at beta.3 describes the pattern; beta.4's own entry was not read).
14. Wire overhead figures in section 10: estimates, not measured.

## Observed baseline (read-only probes, 2026-11-21)

Method: `ssh` read-only (`ps`, `lsof`, `launchctl` plist, `ls`) to Chromedome and Teletran 2, then `openssl s_client` and `curl` (GET `/`, certificate not pinned) from the LAN against every non-loopback listener. **Probed from the LAN, not from outside**, so which ports are reachable from the internet is still the `pf` lists' claim, not a measurement. Only the headers this proposal sets are shown; "none" means none of them appeared on the response to `GET /`.

| Host:port | Service | TLS | Status on `GET /` | Headers this proposal sets |
|---|---|---|---|---|
| Teletran 2:9085 | FleetWatch | 1.3, HTTP/2 | 200 | nosniff, no-store, CSP, referrer-policy, HSTS `max-age=31536000` (hand-rolled, already compliant; the proposal keeps its year) |
| Teletran 2:9100 | VaultMCP web | 1.3 | 404 | CSP, referrer-policy, no-store, nosniff, X-Frame-Options; **no HSTS** |
| Teletran 2:9095 (Hub, public door) | SwiftPushHub | 1.3 | 421 (Host not allowed) | **none** |
| Teletran 2:9140 | ijs-dashboard | 1.3, HTTP/2 | 404 | **none** |
| Chromedome:9110, 9111 | SwiftDiagnosticsHub | 1.3 | 404 | **none** |
| Teletran 2:9086, 9087, 9091; Chromedome:9080 to 9083 | MCP servers (SwiftMCPServer) | 1.3 | 401 | **none** |
| Teletran 2:9088 | ask-the-house | 1.3 | 200 | **none** |
| Chromedome:9084 | iconquer | 1.3 | 426 | **none** |
| Chromedome:9089 | a Python `BaseHTTP` service | **1.2** | 200 | **none**; sends `Server: BaseHTTP/0.6 Python/3.9.6` and `Cache-Control: public, max-age=60` |
| Teletran 2:9094 | Hub loopback door | refused from the LAN | n/a | loopback only, as designed |

What this says for the proposal:
- **The checker has real red results to turn green.** The four kit consumers (Hub 9095, ijs-dashboard 9140, Diagnostics Hub 9110/9111, and FleetWatch is already compliant) are exactly the ones this change reaches, and the Hub's 421 error response shows the "every response path" requirement matters: the refusal carries no headers today.
- **The services this change does not reach** (SwiftMCPServer on seven ports, ask-the-house, iconquer, the Python service) all send none. They are the larger share of the exposed surface and need their own change (open question 7).
- **Chromedome:9089 is a separate finding for SwiftPenTest**, not for this kit: a Python 3.9.6 `BaseHTTP` server on a port `pf` allows from outside, with a version banner and TLS 1.2. Python 3.9 reached end of life in October 2025 (from memory; verify).
- **Observation, unverified:** a `com.roseclub.diagnostics-hub.plist.disabled-20261113` sits in Chromedome's LaunchAgents while a `diagnosti...` process is listening on 9110 and 9111, so it is being started some other way. Not traced.

## Estimate (realistic)

| Step | Effort |
|---|---|
| `git pull`; red tests for the policy and every-path suite (sections 11.1 to 11.2, 11.5) | 0.5 day |
| `ResponseHeaderPolicy` in core, green | 0.25 day |
| Transport wiring: six call sites, `ServerContext`, config carrier, digester check, fix existing tests (11.7 to 11.8) | 0.5 to 1 day (the digester/overload is the uncertainty) |
| H2 coverage and the busy/stream cases | 0.5 day |
| DocC, README, CHANGELOG with links, master plan, quality gate 0/0, tag | 0.5 day |
| **Kit total to tag `1.0.0-beta.5`** | **2 to 2.75 days** |
| Rollout: each dependent bumps the exact pin, runs its tests (a test that asserted a header set may need updating), deploys, runs the checker | 0.25 to 0.5 day each, 1 to 2 days for four, plus soak |

## Staging (rollout order and rollback)

1. Kit `1.0.0-beta.5` tagged; CI green including the API-breaking check.
2. **SwiftDiagnosticsHub first**: it is the checker's target, has a small surface, and already sets `no-store`. Pin bump, deploy to a non-production run if one exists, run `HeadersChecker`; expect red-to-green. (No terminator is in front of any service, section 6.1, so HSTS is the service's own.)
3. **SwiftPushHub** (JSON, none of the headers today).
4. **ijs-dashboard-server** (JSON plus passkey pages; confirm pages unchanged).
5. **FleetWatch last** (HTML, own headers, assets; diff the response headers before and after for every route class, expect only `X-Frame-Options` and HSTS changes).
6. After each: run the checker against it, look at the access log for a rise in 4xx, and for HSTS confirm no plaintext sibling on the same hostname was hit by a browser that had visited.

**Rollback:** each dependent pins `exact`, so rollback is a one-line pin back to `1.0.0-beta.4` and a redeploy. Without a redeploy, nothing in the policy is runtime-configurable. In the code, `ResponseHeaderPolicy.disabled(because:)` is the config-level switch. For HSTS specifically, **a pin rollback does not make browsers forget it**: the header simply stops, and a browser that saw it keeps enforcing for up to max-age (7 days by default; that cap is the real bound on a bad rollout). To actively clear it, ship a *forward* fix serving `.whenServingTLS(maxAge: .zero)` (`max-age=0`) over TLS, and keep it until the window has passed. The longer values are not to be raised until a soak says so. Revert the CHANGELOG entry with the release, not by editing it.
