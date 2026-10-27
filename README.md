# SwiftHTTPService

A small, safe kit for serving a JSON API over HTTP/1.1 and TLS.

**Status:** pre-0.1, untagged, private. The core (request, response, problem, middleware, router, conditional
requests, health route) exists; the transport is being built. Design: `project/plans/proposals/DesignProposal_SwiftHTTPService.md`.

## What it is

- `Request`: a parsed request. The target is parsed strictly and once: origin-form only, split into segments
  before percent-decoding, and anything ambiguous (dot segments, empty segments, a fragment, a bad escape, a
  decoded NUL) is refused rather than normalised.
- `Response`, `Problem`: JSON with sorted keys (so bytes are stable), and RFC 9457 problems with a stable
  `code`. Two problems built from the same inputs are the same bytes.
- `Handler`, `Middleware`, `wrap(_:with:)`: a request becomes a response; middleware wrap handlers.
- `Router`: `/a/{name}/b` patterns, whole-segment matching, no regexes or wildcards. A literal beats a
  parameter, leftmost first, whatever the registration order. Duplicate shapes and malformed patterns are
  refused at registration. `404` and `405` (with `Allow`) are problem details and can be replaced so a server
  can make its refusals indistinguishable. `HEAD` is served by `GET`.
- `EntityTag`, `Conditional`: `If-None-Match` as RFC 9110 defines it (weak comparison, `*`, lists); a value
  that does not parse matches nothing, so the answer is a full response and never a wrong `304`.
- `Router.addHealth()`: `GET /health` with a constant body that reveals nothing.

## Dependencies

Apple's only. The core needs `swift-http-types`; the transport (to come) adds `swift-nio` and `swift-nio-ssl`.

## Develop

```bash
./scripts/bootstrap.sh      # once per clone: enables the git hooks
swift test
quality-gate
```

## Licence

Proprietary. See `LICENSE`.
