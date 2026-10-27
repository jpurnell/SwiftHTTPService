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
- **Dependencies:** `swift-http-types` (core); the transport will add `swift-nio`, `swift-nio-ssl`.

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
└── Health.swift                     Router.addHealth()
Sources/SwiftHTTPServiceNIO/         the transport (to build)
```

---

## Current Status

### What's Working
- [x] Package scaffold, guidelines vendored, design proposal written.
- [x] `Request`: strict origin-form parsing (22 refused targets), segments split before decoding, query.
- [x] `Context`, `Response`, `Problem`, `Handler`, `Middleware`, `wrap`. 33 tests; hand mutations caught.

### What's Next
- [x] `Router`, `Conditional`, `Router.addHealth()`: 66 tests, mutations caught.
- [ ] `ServiceConfiguration` (with the transport, being built in a parallel worktree).
- [ ] The transport target: HTTP/1.1 server, limits, timeouts, connection cap, graceful shutdown, TLS.
- [ ] Rate limiter, request id, access log middleware.
- [ ] A GitHub remote (not created: outward-facing).

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
