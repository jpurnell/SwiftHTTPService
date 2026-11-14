# Session summary, 2026-11-13 to 2026-11-14: beta.2 CI, beta.3, beta.4, the consumers, the soak

## What shipped
| Tag / commit | What |
|---|---|
| `v1.0.0-beta.2` CI follow-ups (`88f2b4d`) | The Linux HAProxy step refreshes the apt index itself and retries. A DNS outage in the runner's container, not the code, failed the next run; re-run green. |
| `e872060` | API-freeze CI step: the macOS job runs `swift package diagnose-api-breaking-changes <baseline tag>`. Checked both ways (clean against beta.2; against beta.1 it reports `RedirectError.origin` as a new enum case). |
| `v1.0.0-beta.3` (`5ad5e82`) | SwiftTLSKit `0.2.1` to `1.0.0-beta.1`, exact pin. No source change. |
| `aa7ddbc` | `project/plans/proposals/ConsumerRequirements.md`: the 2026-10-28 consumer survey, merged from the `consumer-survey` branch. |
| `v1.0.0-beta.4` (`8c3dc82`) | SwiftTLSKit `1.0.0` stable, `.upToNextMinor(from: "1.0.0")`. Resolving also moved swift-nio 2.104.0 to 2.105.0 and swift-nio-ssl 2.37.5 to 2.37.6. No source change since beta.2. API baseline moves to beta.4. |
| `155c1a7` | The macOS CI job runs `swift test --no-parallel`, as Linux does. |

Verification each time: build, all tests (230 and 325 in the two runs), the API-freeze check with no breakage, the push gate. CI green on both jobs for beta.3 (after a re-run; GitHub billing had blocked the first) and beta.4.

## Consumers (all on `main`, none redeployed for the TLSKit 1.0.0 / beta.4 pins)
SwiftPushHub `8860337`, FleetWatch `dafc80f`, ijs-dashboard-server `93b95e9`, SwiftDiagnosticsHub `dce21e3`: SwiftHTTPService `exact 1.0.0-beta.4`, SwiftTLSKit `.upToNextMinor(from: "1.0.0")`; SwiftDiagnosticsHub also takes SwiftPushHub at `8860337`. No source change in any; every test run unchanged.

ijs-dashboard-server was also redeployed on Teletran-2 as a Developer ID signed, **notarized** app bundle (`scripts/package-server.sh`, `Packaging/IJSDashboard-Info.plist`; the ad hoc `build-and-sign.sh` is gone). The launchd job now runs `~/bin/IJSDashboardServer.app`. The Field check passed: fresh cache files were written at the moment of a dashboard request. Rollback: `com.roseclub.ijs-dashboard.plist.bak-20261114` and the untouched old binary in `.build/release`.

## The soak
Started Sat 2026-11-14 10:29 EST on Chromedome at `v1.0.0-beta.4`, `SOAK_SECONDS=248439` (ends about Tue 2026-11-17 07:30). Log `~/soak/soak.log`; independent footprint sampler `~/soak/footprint.csv` (every 5 minutes).

**The test's own resident figure is misleading.** It is `ru_maxrss`, the peak, which never falls. At 3.4 hours it read 283 MB (from 105 MB) while the live footprint was 17 MB and 225 MB of the rest was freed, reclaimable memory in `MALLOC_MEDIUM`. Descriptors flat at 23. Expect the test to report `failed` on its +25% rule even if the kit is fine; judge by `footprint_MB`. Whether that rule should change for 1.0 is open.

## Decisions made
- Soak on Chromedome (it binds 127.0.0.1 and ephemeral ports, so nothing collides with the host's listeners).
- "A week of the beta in the consumers" is waived to Tuesday by the owner.
- Notarize, not ad hoc, for host binaries.
- Do not enable trusted-proxy handling in SwiftPushHub: the public door is a UPnP port forward with no proxy, so the hub already sees real client addresses.

## Things that went wrong, and what they were
- Linux CI failed twice before the real cause: no `apt-get update` in the HAProxy step, then a DNS outage in the container.
- A commit gate failed at `xcode-build`: `build.db database is locked`. I had run two commits in the same worktree; the first attempt's processes survived a `pkill`. Both were stopped and one commit run; it passed.
- The macOS CI job failed once (docs-only commit) in two timing tests that run in parallel there; fixed by running serially.
- I said "nothing deployed" when I only meant by me; the hosts had in fact been redeployed by the swift-oauth beta.11 rollout. Checked and corrected.

## Open
- The soak result and its footprint curve (Tue 2026-11-17 8:00 AM, the vault tickler `development/2026-11-17-decide-swifthttpservice-1.0.0.md`; status note `development/2026-11-14-swifthttpservice-1.0-readiness.md`).
- A clean CI run of `155c1a7` onward on macOS.
- A human outside review, if wanted.
- Hosts still run binaries built on the beta.3 / TLSKit beta.1 pins.
- SwiftHTTPService-ci worktree and `~/soak/` on Chromedome, kept on purpose until the result is recorded.
