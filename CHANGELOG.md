# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project will follow
[Semantic Versioning](https://semver.org/) from 0.1.0.

## [Unreleased]

## [0.2.0] - 2026-10-28

HTTP/2 over TLS. Nothing a caller of 0.1.0 writes changes: `ServiceConfiguration` and `Limits` gain defaulted
parameters, and HTTP/2 is on by default over TLS (`protocols: .http1` turns it off).

### Added: HTTP/2 (`SwiftHTTPServiceNIO`)
Design: `project/plans/proposals/DesignProposal_HTTP2.md`, which reverses D1 of the first design ("not now") at the
owner's request, 2026-10-28.
- Over TLS the server offers `h2` and `http/1.1` in ALPN and the negotiated protocol picks the pipeline. Plaintext
  stays HTTP/1.1: no `h2c`, no `Upgrade`. `ServiceConfiguration.protocols` (`.http1`, `.http1AndHTTP2`, default
  both) narrows it; a protocol that was not offered is never selected, whatever the peer sends.
- `Limits.maximumConcurrentStreams` (1 to 1000, default 100, the RFC 9113 suggested minimum: a recommendation, not
  a measurement). Advertised in SETTINGS and enforced.
- One `StreamHandler` per stream, written on raw frames and not on `NIOHTTPTypesHTTP2`, whose codec has
  `preconditionFailure` paths a peer can reach. The version-independent rules (`RequestRules`, `ResponseRules`,
  `Refusal.response`) are shared with HTTP/1.1; its tests passed unchanged through the extraction.
- A TLS connection that never finishes its handshake is closed at the idle timeout (`HandshakeDeadline`), as the
  HTTP/1.1 pipeline's idle timer used to do before handlers were added after negotiation.
- Dependency: Apple's `swift-nio-http2` (`from: "1.46.0"`), transport target only.
- Tests: 137 in the transport, from 91. Over real TLS with an h2 client; 22 malformed and 8 refused requests
  table-driven from RFC 9113 section 8; the attacks by hand-built frames, with a control showing modest use of
  the same frames is served.
- 27 hand mutations of the HTTP/2 code. 23 were caught. Four survived and none now: three were redundant code,
  removed (a byte check on the target that the core's parser already makes, which was never seen red; the
  grace time given to the library's connection management, which the server's own deadline repeats), and one
  was a missing test (two identical `Content-Length` fields, which the library lets through and the handler
  refuses with 400).

### What `swift-nio-http2` defends and what this package does (measured, not assumed)
- **The library:** all 22 malformed-request cases (pseudo-headers, upper-case names, connection-specific fields,
  CR/LF/NUL, `Content-Length` that is not digits or disagrees with the body) as a stream error of
  `PROTOCOL_ERROR`; rapid reset, small CONTINUATION floods, PING, SETTINGS and empty-DATA floods, each with a
  `GOAWAY` of `ENHANCE_YOUR_CALM` (11); a huge CONTINUATION block with `PROTOCOL_ERROR` (1); a stream past the
  advertised bound; idle connections and the `GOAWAY` handshake of a graceful shutdown
  (`NIOHTTP2ServerConnectionManagementHandler`).
- **This package:** the header-list size (the library advertises `SETTINGS_MAX_HEADER_LIST_SIZE` and does not
  enforce it; counted as RFC 9113 section 6.5.2 does, name plus value plus 32), the header count, the body bound
  with a `NO_ERROR` reset sent only after the response has been written (queued behind it, the reset dropped the
  response's own data), the body timer, `Host` against `:authority`, `Expect`, repeated `Content-Length`, the
  core's target parse, client trailers (refused), and the fixed problem bodies.
- **Not applied to HTTP/2:** `headerReadTimeout`. A header block arrives in one frame sequence bounded by the
  library's CONTINUATION limit; a connection with no stream open is bounded by `idleTimeout`.


## [0.1.0] - 2026-10-28

First release: the core, the HTTP/1.1 transport and TLS through SwiftTLSKit.

### Added
- `Request` with strict target parsing, `QueryItem`, `RequestError`, and `Context` with typed keys.
- `Response` (`json`, `empty`, `notModified`, `problem`, `setting`, `retrying`) and `Problem` (RFC 9457).
- `Handler`, `Middleware` and `wrap(_:with:)`.
- 33 tests. Hand mutations of the parser, the encoder settings and the problem content type were caught; the
  one that survived (a redundant `//` check) was removed.
- `Router` (`add`, `get`/`post`/`put`/`patch`/`delete`, `handler`), `RouterError`; replaceable `notFound` and
  `methodNotAllowed`; `Allow` on a 405. 17 tests worked out by hand, including that no registration order
  changes which handler a request reaches; 10 router mutations caught.
- `EntityTag` and `Conditional` (`ifNoneMatch(_:matches:)`, `respond(to:etag:produce:)`): 28 table cases from
  RFC 9110; 9 mutations caught, 2 only after two cases were added (`Wx"abc"` and a non-ASCII tag in a list).
- `Router.addHealth(at:)`.
- `LICENSE`: proprietary, all rights reserved, for now.

### Transport (`SwiftHTTPServiceNIO`) and configuration
- `ServiceConfiguration`, `Limits`, `TLSFiles`, `ConfigurationError` in the core: a throwing initialiser that
  checks every range and clamps nothing; an error names the field and the kind of fault and never the value;
  the host defaults to `127.0.0.1`. 8 tests, 24 refusals, 15 edges; 18 range mutations, all caught.
- `HTTPServer` (`start() -> BoundAddress`, `reloadTLS(_:)`, `shutdown()`), `BoundAddress`, `HTTPServerError`:
  HTTP/1.1 over TCP, and TLS 1.2 or newer (HTTP/1.1 ALPN only). TLS identity loading, judging and reload are
  the owner's **SwiftTLSKit** (`ServerIdentity`, `ReloadableServerTLS`, `ServerTLSOptions`): every way an
  identity can be unfit is a typed `ServerIdentityError` inside `HTTPServerError.tlsIdentity`, naming the path
  and never the contents; a renewed certificate is taken by `reloadTLS()` with no restart. `BindExposure`
  decides what counts as exposed: plaintext on a host that is not loopback is
  `HTTPServerError.exposedPlaintext(host:)`. A start that fails for either reason can be tried again.
- Enforced: the request line and headers counted as the bytes arrive (`431`), a header-field count (`431`), a
  body limit checked against `Content-Length` before any body is read and against a chunked body as it grows
  (`413`), a header deadline from a request's first byte (`408`; dripping bytes does not extend it), a body
  deadline (`408`), a keep-alive idle timeout (close, nothing written), and a connection cap (closed at once,
  nothing written).
- Refused as ambiguous (`400`): a `Content-Length` with a `Transfer-Encoding`; a duplicate, signed,
  hexadecimal, listed or non-numeric `Content-Length`; a `Transfer-Encoding` other than exactly `chunked`; a
  missing or duplicate `Host` on HTTP/1.1; CR, LF or NUL in a header value; and (through NIO's parser) folded
  lines, bare line feeds and malformed names. A refusal is a fixed `application/problem+json` body that is
  byte for byte what the core's `Response.problem` produces for the same status and code, and never contains
  anything the peer sent or any error text. A handler that throws is a fixed `500` and the connection closes.
- The transport owns `Content-Length`, `Connection`, `Date` and `Transfer-Encoding`: a handler cannot set
  them. `HEAD` carries the headers a `GET` would and no body; `204` and `304` carry no length. `Expect:
  100-continue` is answered with `100` within the body limit and refused with `413` over it; any other
  expectation is `417`.
- Pipelining is not supported: the first request is answered with `Connection: close` and the second is never
  run. A handler that never returns is not bounded by the transport.
- Graceful shutdown is NIOExtras' `ServerQuiescingHelper`: the listening socket closes, every open connection
  is told to quiesce, an idle one closes at once, a busy one finishes its request and closes, and after
  `shutdownGrace` whatever is left is closed. Idempotent, and safe from several tasks.
- 91 transport tests: byte-level pipeline tests on `NIOAsyncTestingChannel`, the connection handler tested
  directly with no parser in front (its own rules must not depend on NIO's), and real loopback sockets for
  the lifecycle, the cap, real timers, TLS, reload, and the typed identity errors. Certificates are generated
  when the tests run (SwiftTLSKitTestSupport), so no key is checked in. Ten consecutive runs of the whole
  suite passed.

### Decisions about `swift-nio-extras` (evaluated before building)
- **Adopted:** `NIOExtras.ServerQuiescingHelper`, in place of a hand-written drain and wait. It also closes a
  connection that arrives during shutdown, which made two flags of ours redundant (removed).
- **Not adopted, `NIOHTTPTypesHTTP1`:** `HTTP1ToHTTPServerCodec` rewrites an absolute-form target such as
  `http://other.example/v1/me` into the path `/v1/me`, so the core's strict origin-form rule would never see
  the original, and it moves the first `Host` into `authority`, so a count of `Host` fields is off by one. Both
  are pinned by `ExtrasBridgeAssumptionTests`; if a later release changes either, revisit.
- **Not adopted, `NIOCertificateReloading`:** it links `swift-service-lifecycle`, which is the Swift Server
  Workgroup's and not Apple's. The owner's SwiftTLSKit does the reload instead (and also the identity checks
  that package does not have).
- **Removed after SwiftTLSKit:** my own `TLSIdentity` (PEM loading, BoringSSL context building, the
  unreadable/rejected errors, minimum version and ALPN), the committed test certificate and key, and the
  direct `swift-nio-ssl` dependency (it still arrives through SwiftTLSKit).
- **SwiftTLSKit is a URL dependency**, `.upToNextMinor(from: "0.2.1")`, in place of the sibling path
  `../SwiftTLSKit`: the package now resolves on its own. SwiftTLSKit needed no new tag; 0.2.1 is the pin.
- Adding `swift-nio-extras` resolves `swift-service-lifecycle` into the lockfile even though nothing links it.

[Unreleased]: https://github.com/jpurnell/SwiftHTTPService/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/jpurnell/SwiftHTTPService/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/jpurnell/SwiftHTTPService/releases/tag/v0.1.0
