# Rig findings (the "unverified paths" tests, 2026-10-30)

What the new test rig found, in the order it was built. A finding is a difference between documented and actual behaviour,
a crash, a hang, or a defect; each names the test that reproduces it. Tests that cannot pass yet are wrapped in
`withKnownIssue`, never disabled.

## 1. Linux CI

`.github/workflows/ci.yml` is written and **has not been run** (Actions cannot run here). No container runtime exists on the
machine that wrote it (`docker`, `podman`, `colima`, `lima`, `container` and `nerdctl` are all absent), so **no Linux build
or test was run**. What a Linux build will meet, from reading `Sources/` and `Tests/`:

- `Sources/SwiftHTTPService`: Foundation only (`NSLock` in `ResponseStream.swift`, `Date`, `Data`). Nothing Apple-only.
- `Sources/SwiftHTTPServiceNIO`: no `os`, `Security` or `Darwin` import. Two places are the likeliest compile friction:
  `ReloadTriggers.swift` calls `signal(SIGHUP, SIG_IGN)` and `signal(SIGHUP, previous)` and uses `DispatchSource.makeSignalSource`;
  on Glibc `signal` returns an optional `__sighandler_t?` where Darwin's is non-optional, and the saved `previous` is used
  as a value to restore. This is the one spot a Linux compile may reject.
- `Package.swift` declares `.macOS(.v14)` and `.iOS(.v17)` only, which does not stop a Linux build.
- The private dependency SwiftTLSKit has `#if canImport(Darwin)` / `Glibc` / `Musl` branches already and imports `os` in three
  files (its own concern; it needs the same check). It is by SSH URL (`git@github.com:`), not HTTPS.
- Tests: `ReloadTriggerTests.swift` reads `sigaction` with both a Darwin (`__sigaction_u`) and a Linux (`__sigaction_handler`)
  branch, the second never compiled. File mode `0o600` through `FileManager` attributes should work on corelibs-foundation.
