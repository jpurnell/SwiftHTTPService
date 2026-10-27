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

### Transport (branch `transport`)
- [x] `ServiceConfiguration`, `Limits`, `TLSFiles`: validated, nothing clamped, errors never carry a value.
- [x] `SwiftHTTPServiceNIO`: `HTTPServer` (start, reload, graceful shutdown), every limit enforced,
  request-smuggling hygiene, fixed refusals, connection cap, real timers. 91 tests; hand mutations of every
  limit and rule, the survivors turned into tests or the redundant code removed.
- [x] TLS is the owner's SwiftTLSKit (path dependency on `../SwiftTLSKit`, transport target only): typed
  identity errors, reload without a restart, `BindExposure` refusing exposed plaintext.
- [x] Evaluated `swift-nio-extras`: adopted `ServerQuiescingHelper`; not `NIOHTTPTypesHTTP1` (it rewrites
  absolute-form targets and consumes `Host`) and not `NIOCertificateReloading` (links a non-Apple package;
  SwiftTLSKit does reload). Reasons are in `CHANGELOG.md` and pinned by tests.
- [ ] A reload trigger (SIGHUP or a timer) is the executable's: `reloadTLS()` is the hook.
- [ ] `../SwiftTLSKit` is a sibling path dependency, so this package resolves only beside a SwiftTLSKit
  checkout; switch to its URL when SwiftTLSKit is tagged for it (it is `0.2.1`, private).
- [ ] HTTP/2, only if a consumer needs it.

### What's Next
- [x] `Router`, `Conditional`, `Router.addHealth()`: 66 tests, mutations caught.
- [x] `ServiceConfiguration` and the transport: HTTP/1.1, limits, timeouts, connection cap, graceful shutdown, TLS through SwiftTLSKit.
- [ ] Rate limiter, request id, access log middleware.
- [ ] Migrate the other hand-rolled servers, after this kit has served real traffic: `project/plans/proposals/MigrationPlan_HandRolledServers.md`.
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
- [ ] ServiceConfiguration

### Phase 2: The transport
- [ ] HTTP/1.1, limits, graceful shutdown, then TLS

### Future
- HTTP/2, only if a consumer needs it.

---

**Last Updated:** 2026-10-27 (router, conditional requests and health route added to the core)
