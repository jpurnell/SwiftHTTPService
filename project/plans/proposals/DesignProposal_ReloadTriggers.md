# Design Proposal: reload triggers

**Status:** Proposed and started 2026-10-28. The roadmap said "a reload trigger (SIGHUP or a timer) is the
executable's: `reloadTLS()` is the hook". SwiftTLSKit already has the loop (`reloadOnEach`) and deliberately no
source of triggers; every executable would write the same two. They go in the transport.

- `TLSReloadTrigger.hangup()`: an `AsyncStream` with one element per `SIGHUP`. It installs a signal source and
  ignores the signal's default action (which is to end the process) for as long as the stream lives; when the
  stream ends it cancels the source and puts back the disposition it found, so an executable that had `SIGHUP`
  ignored (run under `nohup`) is left that way.
- `TLSReloadTrigger.every(_:)`: an `AsyncStream` with one element per interval, for a periodic check. The
  interval is validated (above zero, at most a day), nothing clamped, and the error names the field.
- `HTTPServer.reloadTLS(onEach:mode:report:)`: reloads once per trigger until the sequence ends or the task is
  cancelled. It goes through the server's current state on each trigger, so it can be started before `start()`
  and survives a restart; a trigger that arrives when nothing is serving TLS reports nothing and is dropped.
  `mode` has no default, as in SwiftTLSKit: a signal means `.always`, a timer `.ifChanged`, and the call site
  knows which it holds.
