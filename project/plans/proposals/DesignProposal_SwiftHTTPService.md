# Design Proposal — SwiftHTTPService

**Status:** proposed 2026-10-27, for the owner. **Why now:** `ijs-dashboard-server` needs an HTTP layer, and
the owner chose to build a reusable kit first. The Stack Map lists "General HTTP service kit" (`http-service`)
as a missing capability: *routing, middleware, health checks, config and graceful shutdown for non-MCP
APIs*. Both existing servers (`SwiftMCPServer`, `FleetWatch`) hand-roll their own NIO handling.

## 1. Objective

A small, safe, dependency-light kit for serving a JSON API over HTTP/1.1 and TLS, so that the next server
is routes and handlers, not sockets. First consumer: `ijs-dashboard-server` (19 routes, bearer-token
auth, ETag/304, `application/problem+json`, TLS, graceful shutdown, one process for many tenants).

### Non-goals
- Not a web framework: no templating, no ORM, no sessions, no WebSockets.
- No authentication or authorisation. Those are the server's, and are middleware.
- Not MCP. `SwiftMCPServer` stays as it is; this may be adopted by it later.

## 2. Dependencies (the owner's rule: Apple-vended only)

`swift-http-types` (types), `swift-nio`, `swift-nio-ssl` (transport only). The **core has no NIO**: routing,
middleware and the request/response types are pure, so they are tested without a socket and can run
under any transport.

## 3. Design

Two library products:

| Product | Contains | Depends on |
|---|---|---|
| `SwiftHTTPService` | `Request`, `Response`, `Router`, `Middleware`, `Handler`, problem details, conditional-request helper, configuration with validation | `swift-http-types`, Foundation |
| `SwiftHTTPServiceNIO` | the HTTP/1.1 server: listener, TLS, limits, timeouts, connection cap, graceful shutdown | the core, `swift-nio`, `swift-nio-ssl` |

### 3.1 The core

- `Request`: method, `path` (the raw target's path), `pathSegments` (split, then percent-decoded, so an
  encoded `/` in a segment can never change the route), `query` (name/value pairs, order kept), `headers`
  (`HTTPFields`), `body` (`Data`, already within the limit), `remoteAddress` (string, optional), and
  `pathParameters` filled by the router. A typed `Context` (keys are types, values `Sendable`) carries what
  middleware learns: the request id, the authenticated subject, the tenant.
- `Response`: status, headers, body. Constructors: `.json(_:status:)`, `.problem(_:)` (RFC 9457, with a stable
  `code`), `.empty(_:)`, `.notModified(etag:)`. A body is bytes; encoding is the caller's.
- `Handler = @Sendable (Request) async throws -> Response`. `Middleware = @Sendable (Request, Handler) async
  throws -> Response`. An error that escapes becomes a `500` problem with a fixed body: **the error text is
  never sent** (it can contain paths).
- `Router`: register `(method, pattern, handler)` with patterns like `/v1/corpora/{corpus}/status`. Matching
  is by whole segment; a `{name}` matches exactly one non-empty segment; there are no regexes and no
  wildcards. Specificity is deterministic: a literal segment beats a parameter. Duplicate or ambiguous
  registrations **fail at registration**, not at request time. An unknown path is `404`; a known path with
  another method is `405` with an `Allow` header; `HEAD` is answered from `GET`'s handler with no body.
  `404` and `405` handlers are replaceable so a server can make them byte-identical to other refusals.
- Middleware are applied in registration order, outermost first. Provided: request id (incoming id kept only
  if well-formed, else generated), access log (an injected sink, no bodies, no query values, no
  authorisation header), a keyed rate limiter (token bucket, injected clock), `Conditional` (ETag +
  `If-None-Match` → `304`, weak/strong comparison as RFC 9110 says).
- `ServiceConfiguration`: bind host and port, TLS file paths, and every limit (header bytes, body bytes,
  header read timeout, body read timeout, idle timeout, max connections, shutdown grace). **Validated**: an
  out-of-range or contradictory value refuses to start; there is no silent clamp.

### 3.2 The transport

HTTP/1.1 over TCP and TLS 1.2+. The point of the module is the limits and the lifecycle:

- bounded header size and count, bounded body, a read deadline for the header and another for the body
  (slowloris), an idle keep-alive timeout, a cap on concurrent connections, and `Connection: close` when a
  limit is hit;
- request smuggling hygiene: reject a request with both `Content-Length` and `Transfer-Encoding`, a
  duplicate or non-numeric `Content-Length`, obsolete line folding, and bare `\r` or `\n`;
- graceful shutdown: stop accepting, let in-flight requests finish up to the grace period, then close;
- a health route registered by the kit (`/health`, no auth, constant body) so supervisors can probe it;
- it never logs a header value or a body.

### 3.3 Testing

Core: pure unit tests, including a table of routing cases worked out by hand and property checks that no
registration order changes which handler a request reaches. Transport: `NIOEmbedded` for the byte-level
parsing and limit tests, and a real loopback listener on an ephemeral port with `URLSession` for the
lifecycle. Mutation checks by hand on every limit.

## 4. Slices

1. **Core** (no NIO): types, router, middleware chain, problem details, conditional helper, configuration.
2. **Transport**: HTTP/1.1 server, limits, timeouts, connection cap, graceful shutdown, health route.
3. **TLS**: `swift-nio-ssl`, certificate and key from files, reload without dropping connections if cheap.
4. **Extras**: rate limiter, access log, request id as middleware, if not already in slice 1.

## 5. Decisions needed

- **D1 — HTTP/2.** ~~Not now. HTTP/1.1 is enough for one consumer behind a home router.~~ Reversed 2026-10-28 at the owner's request: see `DesignProposal_HTTP2.md`.
- **D2 — Linux.** The kit uses nothing Apple-only, so Linux should build; it is not tested until the
  Linux CI gap (Stack Map #3) is closed. Stated, not promised.
- **D3 — adopting it in `SwiftMCPServer`.** Out of scope here.
