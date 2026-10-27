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
- `Router` (`add`, `get`/`post`/`put`/`patch`/`delete`, `handler`), `RouterError`; replaceable `notFound` and
  `methodNotAllowed`; `Allow` on a 405. 17 tests worked out by hand, including that no registration order
  changes which handler a request reaches; 10 router mutations caught.
- `EntityTag` and `Conditional` (`ifNoneMatch(_:matches:)`, `respond(to:etag:produce:)`): 28 table cases from
  RFC 9110; 9 mutations caught, 2 only after two cases were added (`Wx"abc"` and a non-ASCII tag in a list).
- `Router.addHealth(at:)`.
- `LICENSE`: proprietary, all rights reserved, for now.
