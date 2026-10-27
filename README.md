# SwiftHTTPService

A small, safe kit for serving a JSON API over HTTP/1.1 and TLS.

**Status:** pre-0.1, untagged, private. The core's request, response, problem and middleware types exist; the
router and the transport do not yet. Design: `project/plans/proposals/DesignProposal_SwiftHTTPService.md`.

## What it is

- `Request`: a parsed request. The target is parsed strictly and once: origin-form only, split into segments
  before percent-decoding, and anything ambiguous (dot segments, empty segments, a fragment, a bad escape, a
  decoded NUL) is refused rather than normalised.
- `Response`, `Problem`: JSON with sorted keys (so bytes are stable), and RFC 9457 problems with a stable
  `code`. Two problems built from the same inputs are the same bytes.
- `Handler`, `Middleware`, `wrap(_:with:)`: a request becomes a response; middleware wrap handlers.

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
