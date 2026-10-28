# Design Proposal: HTTP/2 in the transport

**Status:** Proposed, 2026-10-28. Supersedes D1 of `DesignProposal_SwiftHTTPService.md` ("Not now"). The owner
decided on 2026-10-28 to enable HTTP/2 now rather than wait for a consumer.

## 1. Goal

`SwiftHTTPServiceNIO` serves HTTP/2 as well as HTTP/1.1, with the same limits, the same refusals in spirit, the
same graceful shutdown and the same handler. A handler (`Handler`) cannot tell which version carried the request.
The core (`SwiftHTTPService`) does not change and still links no NIO.

## 2. What exists

The pipeline is built once per connection in `PipelineBuilder`: TLS, `HeadGuard`, the HTTP/1.1 decoder and encoder,
`ConnectionHandler` (one request at a time, no pipelining). ALPN is offered as `["http/1.1"]` only. HTTP/2 is
named in the README as "not supported, on purpose".

## 3. Proposed design

### 3.1 Dependency
Add Apple's `swift-nio-http2` (latest tag 1.46.0; already in `Package.resolved` through SwiftTLSKit's graph),
`from: "1.46.0"`, **transport target only**. `swift-nio-ssl` still arrives through SwiftTLSKit.

### 3.2 Negotiation
- Over TLS: offer ALPN `["h2", "http/1.1"]` through `ServerTLSOptions.applicationProtocols`; the negotiated
  protocol picks the pipeline. No ALPN result, or `http/1.1`, gets today's pipeline unchanged.
- Plaintext: HTTP/1.1 only. No `h2c`, neither prior-knowledge nor `Upgrade` (the latter is deprecated by
  RFC 9113, and the transport refuses `Upgrade` today). Plaintext is for loopback, where HTTP/2 buys nothing.
- A configuration switch, `ServiceConfiguration.protocols` (`.http1`, `.http1AndHTTP2`), defaulting to both, so
  a consumer can turn it off. Validated like the rest; nothing clamped.

### 3.3 Structure
One connection-level `NIOHTTP2Handler` with the stream multiplexer, one child channel per stream, and **one
`StreamHandler` per stream** that turns the stream's frames into the same `Request` the HTTP/1.1 path builds and
writes the `Response` back. Shared with `ConnectionHandler`, extracted rather than copied: request validation
that is not wire-specific, the refusal bodies, the body-size cap, the handler call, the response-header rules.
HTTP/1.1 behaviour does not change, and its 91 tests are the proof.

### 3.4 Limits, mapped
| HTTP/1.1 limit | HTTP/2 |
| --- | --- |
| head size, header count | `SETTINGS_MAX_HEADER_LIST_SIZE` advertised and enforced; header count enforced on the decoded list |
| body size | counted per stream across DATA frames; `Content-Length` checked against it (declared length that disagrees with the DATA received is a stream error) |
| connection cap | unchanged: counts TCP connections |
| request/idle/body timers | per stream for the head and body; per connection for idle |
| (none) | **new:** `maximumConcurrentStreams` (advertised as `SETTINGS_MAX_CONCURRENT_STREAMS`, and enforced) |
| shutdown | `GOAWAY` with the last accepted stream, then the existing grace period |

### 3.5 Attacks specific to HTTP/2, each needing a test that fails without the defence
Rapid reset (CVE-2023-44487): a cap on streams reset per window, then `GOAWAY(ENHANCE_YOUR_CALM)`. CONTINUATION
flood: header-block size bounded across frames, not per frame. PING, SETTINGS and empty-frame floods: a bound on
control frames per window. Stream-window and connection-window exhaustion: we read the body as it arrives and
cap it, so a peer cannot make us buffer more than the body limit. Which of these `swift-nio-http2` already
refuses is **measured, not assumed**, and recorded in the changelog the way the `swift-nio-extras` evaluation was.

### 3.6 Validation (RFC 9113 §8)
Pseudo-headers: exactly `:method`, `:scheme`, `:path` (and `:authority`), none repeated, none after a regular
field; `:path` goes through the core's strict origin-form `Request` parse, so the 22 refused targets are refused
here too. Connection-specific fields (`Connection`, `Keep-Alive`, `Proxy-Connection`, `Transfer-Encoding`,
`Upgrade`) are refused; `TE` only as `trailers`. `Host` and `:authority` must agree if both are present. Uppercase
field names refused. CR, LF and NUL in values refused, as in HTTP/1.1. Refusals use the same fixed problem bodies.

### 3.7 Out of scope
Server push (disabled by setting), priorities, trailers from the client (refused unless a consumer needs them),
`CONNECT`, WebSockets over HTTP/2, h2c.

## 4. Slices (TDD, each red then green)
1. `ServiceConfiguration.protocols` and the ALPN offer; HTTP/1.1 tests still pass.
2. Extract the shared request/response logic from `ConnectionHandler`; no behaviour change.
3. A single stream: GET and POST round trip over h2 with `NIOEmbedded` and a real TLS test (certificates from
   `SwiftTLSKitTestSupport`).
4. Validation (3.6), table-driven, expected values from the RFC.
5. Limits and timers (3.4).
6. The attacks (3.5), then GOAWAY shutdown.
7. Hand mutations of every limit and rule; survivors become tests or the code goes.

## 5. Decisions needed
- **H1 — plaintext h2c.** Recommend **no** (above). 
- **H2 — default.** Recommend HTTP/2 **on** by default for TLS, since the owner wants it now.
- **H3 — a default for `maximumConcurrentStreams`.** Recommend 100 (the RFC's suggested minimum); the number
  is a recommendation, not a measurement, and is revisited with the first real h2 traffic.
- **H4 — client trailers.** Recommend refused (a stream error) until a consumer needs them.
- **H5 — the SwiftTLSKit pin.** `["h2", "http/1.1"]` needs nothing new there (ALPN is already a list).
  If a TLS-level h2 check wants a SwiftTLSKit change, that is a 0.2.2 or 0.3.0 and is raised first.
