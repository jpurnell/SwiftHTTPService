# SwiftHTTPService Master Plan

**Purpose:** Source of truth for project vision, architecture, and goals.

---

## Project Overview

### Mission
A small, safe kit for serving a JSON API over HTTP/1.1 and TLS: routing, middleware, problem details,
conditional requests, validated configuration and a bounded transport. It closes the Stack Map's
`http-service` gap. The design is `project/plans/proposals/DesignProposal_SwiftHTTPService.md`.

### Target Users
- `ijs-dashboard-server` (first consumer): 19 routes, bearer auth, ETag/304, problem+json, TLS, graceful shutdown.
- Later servers, so they are routes and handlers and not sockets.

### Key Differentiators
- The core has no NIO: routing and middleware are pure and tested without a network.
- Apple-vended dependencies only (`swift-http-types`; the transport adds `swift-nio` and `swift-nio-ssl`).
- Strict by default: an ambiguous request target is refused, not normalised; a configuration that
  contradicts itself refuses to start; an error's text is never sent to a client.

---

## Architecture

### Technology Stack
- **Language:** Swift 6.2+ (manifest 6.2 on purpose)
- **Build System:** Swift Package Manager, macOS 14. Nothing Apple-only, so Linux should build (untested).
- **Testing:** Swift Testing
- **Concurrency:** Swift 6 strict concurrency throughout
- **Dependencies:** `swift-http-types` (core); the transport adds `swift-nio`, `swift-nio-ssl` and `swift-nio-extras`.

### Module Structure

```
Sources/SwiftHTTPService/            the core, no NIO
├── Request.swift                    strict target parsing, path segments, query
├── Context.swift                    typed values middleware attach
├── Response.swift                   json, empty, notModified, problem
├── Problem.swift                    RFC 9457
├── Middleware.swift                 Handler, Middleware, wrap(_:with:)
├── Router.swift                     patterns, specificity, 404/405, HEAD
├── Conditional.swift                EntityTag, If-None-Match, 304
├── Health.swift                     Router.addHealth()
└── ServiceConfiguration.swift       validated configuration and Limits
Sources/SwiftHTTPServiceNIO/         the transport: HTTPServer, HeadGuard, ConnectionHandler, PipelineBuilder, ConnectionRegistry
```

---

## Current Status

### What's Working
- [x] Package scaffold, guidelines vendored, design proposal written.
- [x] `Request`: strict origin-form parsing (22 refused targets), segments split before decoding, query.
- [x] `Context`, `Response`, `Problem`, `Handler`, `Middleware`, `wrap`. 33 tests; hand mutations caught.

### Transport (~~branch `transport`~~ merged into `main`, `20ab1b8`, 2026-10-27)
- [x] `ServiceConfiguration`, `Limits`, `TLSFiles`: validated, nothing clamped, errors never carry a value.
- [x] `SwiftHTTPServiceNIO`: `HTTPServer` (start, reload, graceful shutdown), every limit enforced,
  request-smuggling hygiene, fixed refusals, connection cap, real timers. 91 tests; hand mutations of every
  limit and rule, the survivors turned into tests or the redundant code removed.
- [x] TLS is the owner's SwiftTLSKit (URL dependency, `.upToNextMinor(from: "0.2.1")`, transport target only): typed
  identity errors, reload without a restart, `BindExposure` refusing exposed plaintext.
- [x] Evaluated `swift-nio-extras`: adopted `ServerQuiescingHelper`; not `NIOHTTPTypesHTTP1` (it rewrites
  absolute-form targets and consumes `Host`) and not `NIOCertificateReloading` (links a non-Apple package;
  SwiftTLSKit does reload). Reasons are in `CHANGELOG.md` and pinned by tests.
- [x] ~~A reload trigger (SIGHUP or a timer) is the executable's: `reloadTLS()` is the hook.~~ Shipped in 0.3.0 as
  `TLSReloadTrigger` and `HTTPServer.reloadTLS(onEach:)`, though the plan had left it to the executable: every
  executable would have written the same two.
- [x] ~~`../SwiftTLSKit` is a sibling path dependency~~ now a URL dependency, pinned to `0.2.1` (no new SwiftTLSKit tag was needed).
- [x] ~~HTTP/2, only if a consumer needs it.~~ Done 2026-10-28 at the owner's request, before any consumer asked: it shipped
  despite the stated bar. `DesignProposal_HTTP2.md`; 137 transport tests; 27 hand mutations, all caught or removed.

### What's Next
- [x] `Router`, `Conditional`, `Router.addHealth()`: 66 tests, mutations caught.
- [x] `ServiceConfiguration` and the transport: HTTP/1.1, limits, timeouts, connection cap, graceful shutdown, TLS through SwiftTLSKit.
- [x] ~~Rate limiter, request id, access log middleware.~~ Shipped in 0.3.0: `DesignProposal_Middleware.md`; 27 mutations.
- [x] **Order (owner, 2026-10-28):** v0.1.0 is a milestone, not the finish. Get the kit feature complete first, then
  migrate the services that can use it. Feature complete as of 0.3.0 (HTTP/2, the middleware, reload
  triggers, the shutdown fix); a consumer's findings then added the 0.4.0 items under "Next release" below, which
  come before migration. Migration's own decisions (below) are the owner's.
- [ ] Migrate the other hand-rolled servers, after the 0.4.0 items below, and once the kit has served real traffic: `project/plans/proposals/MigrationPlan_HandRolledServers.md`.
  **Gate A was waived by the owner on 2026-10-29** (the dashboard server moved to 0.4.0 on Teletran 2 that day; one consumer
  on one golden path is too weak a soak to wait for): each migration carries its own recorded-exchange replay, a run beside
  the old server and a rollback binary instead. SwiftPushHub, first in line, turned out to be live (v1.0.1, running), not
  "nothing runs yet" as the plan assumed; see the migration plan section 4.1.
  **Real traffic began 2026-10-28:** `ijs-dashboard-server`, deployed on Teletran 2 (port 9140), runs on this kit. The
  plan's decisions are all still open: D1 (how long it must run cleanly before anything migrates, so the clock
  has started but its length is not set), D2 (streaming responses), D3 (tail wildcards) and D4 (whether FleetWatch
  migrates at all).
- [x] ~~**A release.**~~ `v0.1.0` tagged 2026-10-28. `ijs-dashboard-server` still names the package by path (`../SwiftHTTPService`); moving it to the tag is its own change.
- [x] ~~The test run prints "Cannot schedule tasks on an EventLoop that has already shut down".~~ Fixed in 0.3.0: three causes,
  two of them real shutdown bugs (see the CHANGELOG), and a test that watches standard error.
- [x] A GitHub remote: `jpurnell/SwiftHTTPService` (private).

---

## Quality Standards

### Code Quality
- All code follows `coding_rules.md`
- TDD: failing tests before implementation
- Documentation for all public APIs
- No warnings in build output
- Quality gate: 0 errors, 0 warnings before every commit

### Documentation Quality
- DocC comments for all public functions
- Usage examples in documentation
- Articles for complex topics

---

## Collaboration Principles

### AI as Sparring Partner, Not Oracle

AI proposes; the human interrogates. High AI confidence triggers harder questions, not faster acceptance.

- **Interrogate confident outputs.** When the AI states something with certainty, ask for the counterargument before accepting.
- **Demand counterarguments.** Before locking in an approach, require an explicit case for the strongest alternative.
- **Sit with discomfort.** Resist the pull to take the first plausible answer.

This principle is operationalized in the **Adversarial Review** step of `design_proposal.md`.

---

## Roadmap

### Phase 1: The core
- [x] Request, Context, Response, Problem, Middleware
- [x] Router, Conditional, health route
- [x] ServiceConfiguration (the box had been left open after it shipped)

### Phase 2: The transport
- [x] HTTP/1.1, limits, graceful shutdown, then TLS (merged 2026-10-27; in service under `ijs-dashboard-server`
  from 2026-10-28)

### Phase 3: Release
- [ ] 0.1.0: SwiftTLSKit by URL, then the tag, then `ijs-dashboard-server` names it by version

### Released: 0.4.0 (2026-10-29), before migration begins
Scope widened by the owner's migration decisions (2026-10-29: D2 streaming, D4 full FleetWatch migration): see
`DesignProposal_0.4.0.md`, which is also the build order. The list below is the consumer's findings; the proposal
adds the gaps D4 turns into requirements (forms, assets, redirects and cookies, close-after-response mode).
Candidates from a consumer's findings (a worker building on the kit, relayed by the owner 2026-10-29). The owner's
decision (2026-10-29): these go into a 0.3.1 or a 0.4.0 before migration starts. They add public API, and before 1.0
this package signals a source break with the minor version, so the working assumption is 0.4.0. Each wants a design
note before code.
- [x] ~~`Request` has no HTTP version~~, so a handler cannot tell which one carried it. The design said a handler should
  not need to, and it may still not; the question is what a consumer needed it for.
- [x] ~~Trusted proxy and the PROXY protocol~~. `remoteAddress` is the socket address only, so behind a proxy every
  client is the proxy: the rate limiter's default key (documented), and the access log's `remote`. Needs a decision
  on whom to trust, which is a security decision before it is a feature.
- [x] ~~A transport refusal hook~~: the transport's own refusals (`400`, `408`, `413`, `431`) are fixed bodies, and a
  server that wants them in its own shape or counted has no way in. Also the means to make them indistinguishable
  from the server's other refusals, as the `404`/`405` replacement already allows.
- [x] ~~Response streaming.~~ This is migration decision D2.
- [x] ~~Per-route limits~~ (a larger body bound for one upload route, a tighter rate for a login route).
- **All of the above, and the gaps migration decision D4 turned into requirements (forms, assets, redirects and cookies,
  close-after-response), shipped in 0.4.0 on 2026-10-29.** What is next is migration itself, which waits for its Gate A
  (`ijs-dashboard-server` running a tagged 0.4.0 for about 3 days: `MigrationPlan_HandRolledServers.md` section 6).
- Already answered by 0.3.0: the shutdown error (fixed), and an unlogged failed reload (`reloadTLS(onEach:report:)`
  hands the caller every outcome, `.failed` included, with `suggestedLogLevel`).

- ~~HTTP/2, only if a consumer needs it.~~ Shipped ahead of any consumer (2026-10-28); see Current Status.

---

**Last Updated:** 2026-10-29 (Gate A waived by the owner; SwiftPushHub found to be live, not unbuilt; `ijs-dashboard-server` deployed on v0.4.0; v0.4.0 released: streaming, trusted proxies and the PROXY protocol, refusal hooks, per-route limits, forms, typed responses, redirects and cookies, close-after-response, `Request.httpVersion`; the migration gaps are closed; migration decisions D1 to D4 made by the owner and recorded; 0.4.0 scope widened; a consumer's findings recorded under Future; v0.3.0: the middleware, reload triggers and the stopped-loop fix shipped, the roadmap items struck through, the kit feature complete; before that, 2026-10-28: v0.2.0 released with HTTP/2; HTTP/2 built and recorded: design, changelog, README, roadmap items struck through; v0.1.0 tagged; SwiftTLSKit path dependency became a URL pin at 0.2.1; roadmap ordered feature-complete before migration. Earlier that day, reconciled: the transport merged, Phase 1 and 2 boxes ticked, the first real
traffic (the deployed `ijs-dashboard-server`) and the migration plan's open decisions recorded, the missing release
added as Phase 3; README status and CHANGELOG link. Earlier, 2026-10-27: router, conditional requests and health
route added to the core)
