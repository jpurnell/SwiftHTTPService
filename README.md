# SwiftHTTPService

A small, safe kit for serving a JSON API over HTTP/1.1 and TLS.

**Status:** pre-0.1, untagged, private. The core (request, response, problem, middleware, router, conditional
requests, health route, validated configuration) and the HTTP/1.1 transport exist and are tested. ~~nothing runs on
them yet.~~ Its first consumer, `ijs-dashboard-server`, has served on it since 2026-10-28 (Teletran 2), naming it by
path because there is no release yet; a 0.1.0 is needed. Design: `project/plans/proposals/DesignProposal_SwiftHTTPService.md`.

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

## The transport (`SwiftHTTPServiceNIO`)

```swift
let configuration = try ServiceConfiguration(port: 8443, tls: TLSFiles(certificateChainPath: "...", privateKeyPath: "..."))
let server = HTTPServer(configuration: configuration) { request in try .json(["hello": "world"]) }
let address = try await server.start()      // the port actually bound (port 0 asks the system for one)
await server.shutdown()                     // graceful: drains, then closes after the grace period
```

HTTP/1.1 over TCP, with TLS (1.2 or newer, HTTP/1.1 only) when configured. `ServiceConfiguration` holds the
certificate and key as **paths**; the identity is loaded, judged and reloaded by the owner's **SwiftTLSKit**:
a missing or unreadable file, a key others can read, a key that does not match, an empty or invalid chain
and an expired leaf each stop `start()` with `HTTPServerError.tlsIdentity(...)` carrying SwiftTLSKit's typed
error (it names the path, never the contents), and the server can be started again once they are fixed.
`server.reloadTLS()` takes a renewed certificate without a restart (new connections get it, open ones are
untouched; unfit files leave the old identity serving and say so). **Plaintext is for loopback**: the host
defaults to `127.0.0.1`, and a host SwiftTLSKit's `BindExposure` calls exposed (`0.0.0.0`, a name, a LAN
address) with no TLS identity is `HTTPServerError.exposedPlaintext`. Every limit in `Limits` is enforced, and
none is clamped; a value out of range makes `ServiceConfiguration` throw an error that names the field and
not the value.

| Limit | Default | Range | What happens when it is hit |
|---|---|---|---|
| `maximumHeaderBytes` | 16 KiB | 1 KiB to 1 MiB | `431`, close. Counted as the bytes arrive, request line included |
| `maximumHeaderCount` | 100 | 1 to 1000 | `431`, close |
| `maximumBodyBytes` | 1 MiB | 0 to 64 MiB | `413`, close. Checked against `Content-Length` before any body is read |
| `headerReadTimeout` | 10 s | up to 1 h | `408`, close. A deadline on the whole head from its first byte, so dripping bytes does not extend it |
| `bodyReadTimeout` | 30 s | up to 1 h | `408`, close |
| `idleTimeout` | 60 s | up to 1 h | close, nothing written. Applies between requests and before the first byte |
| `maximumConnections` | 256 | 1 to 100,000 | the connection is closed at once with nothing written |
| `shutdownGrace` | 10 s | 0 to 10 min | whatever is still open when it ends is closed |

**Refused as ambiguous (`400`, close):** a `Content-Length` with a `Transfer-Encoding`; a duplicate, signed,
hexadecimal, listed or non-numeric `Content-Length`; any `Transfer-Encoding` other than exactly `chunked` (and
any on HTTP/1.0); a missing or duplicate `Host` on HTTP/1.1; a header value with CR, LF or NUL; folded lines and
bare line feeds (by NIO's parser); a target that is not strict origin-form (by the core's `Request`). A refusal
is a fixed `application/problem+json` body that never repeats anything the peer sent.

**Not supported, on purpose:** pipelining (the first request is answered with `Connection: close` and the second
is never run), `Upgrade`, and HTTP/2. **Not bounded here:** the time a handler takes. A handler that never
returns keeps its connection open until it returns, the peer leaves, or a shutdown's grace period ends.

## Dependencies

The core needs `swift-http-types` and nothing else. The transport adds Apple's `swift-nio` and
`swift-nio-extras` (for `ServerQuiescingHelper`, which does the graceful shutdown) and the owner's
**SwiftTLSKit**, as a path dependency on a sibling checkout (`../SwiftTLSKit`) of the transport target only.
Resolving `swift-nio-extras` also resolves its own dependencies, one of which, `swift-service-lifecycle`, is
the Swift Server Workgroup's and not Apple's; nothing in this package links it.

## Develop

```bash
./scripts/bootstrap.sh      # once per clone: enables the git hooks
swift test
quality-gate
```

## Licence

Proprietary. See `LICENSE`.
