# Implementation Checklist: secure-by-default response headers (1.0.0-beta.5)

**Design:** `project/plans/proposals/SecurityHeaders.md` (approved 2026-11-21; Q4/Q5/Q7/Q8 take bracketed defaults)
**Branch:** `feature/security-headers` · **API baseline:** `v1.0.0-beta.4`
**Workflow:** Design-First TDD. Commit at each green state; quality gate 0/0, no suppressions.

## Current Phase: 5. Quality gates passed (51/51, strict); release steps remain

### 0. Design Proposal
- [x] Objective, architecture, API surface, constraints, test strategy (proposal sections 1-4, 11-12)
- [x] Open questions resolved or deferred with defaults (section 17)
- [x] Proposal approved by owner 2026-11-21 and committed
- [x] **Spike (done 2026-11-21):** carrier = option 4.3.1 with a **required** (not defaulted) `responseHeaders:` on a second `init` overload; the original `init` delegates with `.secure`. The consumers' argument lists (SwiftPushHub, SwiftDiagnosticsHub, ijs, no-argument) compile with no ambiguity; `diagnose-api-breaking-changes v1.0.0-beta.4` reports no breaking changes in either module. Fallbacks 2 and 3 not needed.

### 1. Tests (RED), proposal section 11
- [x] 11.1 `ResponseHeaderPolicyTests` (core, pure): defaults, handler value wins, case-insensitive, no duplicates, API CSP on json/problem/+json/empty/302 and not html/SSE/png, XFO on html, HSTS only `overTLS`, `.off`, no `includeSubDomains`/`preload`, `disabled(because:)` blank throws, Equatable
- [x] 11.2 `SecurityHeadersEveryPathTests` (NIO, embedded channel), HTTP/1.1 and HTTP/2: 200 json, problem, 204, 304, HEAD, router 404/405 + custom, middleware 401/429/403, health, thrown-error 500, every `Refusal.allCases`, busy (plaintext + H2), streaming head, `eventStream` (single `no-store`)
- [x] 11.4 TLS knowledge: `tls != nil` gives HSTS on every path, nil gives none
- [x] 11.5 No `Server`/`X-Powered-By`, no `NIO`/version string in any value
- [x] 11.6 Hub-shaped regression: exactly one `Cache-Control`
- [x] 11.7 Consumer call-site compile test (overload ambiguity)
- [x] All new tests confirmed RED for the right reason (core 12 of 19 fail on missing headers / opt-out; 7 pass until GREEN because the scaffold changes nothing: handler-wins, Vary, no-CSP-on-HTML, carrier. Re-check they can fail at GREEN. HTTP/1.1 12 of 12, HTTP/2 + busy 3 of 3, all on header expectations only). HTTP/2 and busy tests use a real loopback TLS server like the existing H2 suites, not embedded frames (proposal 11.2 said embedded).

### 2. Implementation (GREEN)
- [x] `Sources/SwiftHTTPService/ResponseHeaderPolicy.swift` (policy, `HSTS`, `secure`, `disabled(because:)`, `applying(to:overTLS:)`)
- [x] `ServiceConfiguration` carries the policy (per spike result)
- [x] `ResponseRules.prepare(_:policy:overTLS:)`; old signature **removed**
- [x] `ServerContext`: `headerPolicy`, `overTLS`; six call sites updated (`BusyRefusalHandler`, `ConnectionHandler` x2, `StreamHandler` x2, `BusyStreamHandler`)
- [x] `HTTPServer.responseHeaderPolicy` exposed (Q5 default)
- [x] Full suite green (core 250/250; NIO green in the gate; one StreamingHTTP1 timing failure in a serial run under load ~360, 5/5 alone); existing tests that asserted exact header sets updated by adding headers, not weakening (11.8)

### 3. Refactoring
- [x] No force unwraps / `try!` / `as!`; field names via constants or guarded construction (no `preconditionFailure`)
- [x] No new `@unchecked Sendable`; policy is an immutable `Sendable` value
- [x] Tests still green

### 4. Documentation
- [x] DocC on every public symbol, with example
- [x] README: "Response headers" section (status line moves with the release)
- [x] CHANGELOG: `### Changed (behavior)` (list incl. XFO-on-HTML and redirect CSP), `### Added`, link-reference definitions
- [x] `project/master_plan.md`: Current Status item, Last Updated note
- [ ] Note for SwiftPenTest `Phase2-Checkers.md` 5.3 (table in proposal section 9)
- [ ] Session summary

### 5. Quality Gates
- [ ] `swift build` clean, `swift test` serial green (macOS)
- [x] `quality-gate` 0 errors / 0 warnings, no overrides (2026-11-21, uncached, --strict, 51 of 51)
- [ ] API-breaking check clean vs beta.4; `API_BASELINE` moved to beta.5 at release
- [ ] Tag `1.0.0-beta.5`; consumers bump per Staging (Diagnostics Hub, PushHub, ijs, FleetWatch)

### Blocked
- none
