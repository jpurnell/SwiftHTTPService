# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project will follow
[Semantic Versioning](https://semver.org/) from 0.1.0.

## [Unreleased]

### Added
- `Request` with strict target parsing, `QueryItem`, `RequestError`, and `Context` with typed keys.
- `Response` (`json`, `empty`, `notModified`, `problem`, `setting`, `retrying`) and `Problem` (RFC 9457).
- `Handler`, `Middleware` and `wrap(_:with:)`.
- 33 tests. Hand mutations of the parser, the encoder settings and the problem content type were caught; the
  one that survived (a redundant `//` check) was removed.
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
- 90 transport tests: byte-level pipeline tests on `NIOAsyncTestingChannel`, the connection handler tested
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
- Adding `swift-nio-extras` resolves `swift-service-lifecycle` into the lockfile even though nothing links it.
