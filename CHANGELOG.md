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
