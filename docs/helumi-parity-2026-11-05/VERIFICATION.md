# Implementation verification — 2026-11-05

Scope: personal Mac cloud drive; sharing and public file requests excluded. Results below distinguish source-level implementation, synthetic integration evidence and actual release qualification. No production bucket, installed app, existing encryption key or real Keychain item was changed by tests.

## Evidence directory

`build/helumi-parity-current/` contains local logs, fixture reports, candidate builds and an artifact manifest. It is ignored build output; this document preserves the interpretation. `IMPLEMENTATION.md` maps features to source files and describes outstanding work.

## Final consolidated tests

`swift test` completed successfully against the combined implementation (`final-swift-tests.log`):

| Target | Tests | Passed | Skipped | Failures |
|---|---:|---:|---:|---:|
| App | 303 | 302 | 1 | 0 |
| Filesystem adapter | 6 | 6 | 0 | 0 |
| Core | 140 | 140 | 0 | 0 |
| **Total** | **449** | **448** | **1** | **0** |

The one skipped test is the search-panel keyboard-focus/render test on the locked desktop. Earlier full-suite attempts recorded that environmental failure; `pre-final-full-tests-locked-focus.log` preserves it. The final run retains the focus assertions and skips only the explicit login-window environment.

The final run includes encryption/recovery, trash/collision/replay, boot-session launch recovery, multi-selection rejection before mutation, stable search selection, availability corruption/generation/budget checks, rate persistence/concurrency and upload scheduler regressions. Separate Python checks: **33 passed** (`final-signing-tests.log`).

## Build results

- `swift build --product CloudDriveEngine`: passed.
- Xcode Debug app build with FinderSync packaging: passed. App and owner signature checks passed. The package is a local candidate, not installed or notarized.
- FinderSync Debug and FSKit Release standalone builds: passed. FSKit remains unsigned/unembedded because the required profile is unavailable.
- Python packaging/qualification-tool checks: 33 passed.
- `git diff --check`: clean.

`artifact-manifest.json` retains SHA-256 identities for the app, packaged owner, FinderSync binary, standalone FSKit binary and implementation/test/script source files. The worktree includes earlier uncommitted work; the manifest does not claim a clean committed release.

## Process fixture results

Packaged owner binary SHA-256: `036cc55bd0adcf5bceffa19d0b231eae56bf83fb78a334dbcb5df39331c9f2c5`.

| Mode | Result | Rename samples | p50 | p95 | p99 |
|---|---|---:|---:|---:|---:|
| Compatible | All five scenario groups pass | 25 | 3.86 ms | 16.99 ms | 17.53 ms |
| Managed | All five scenario groups pass | 25 | 3.41 ms | 11.19 ms | 26.60 ms |

These two generated fixtures ran concurrently on this host. Results include local IPC and are not comparable to a controlled mounted-volume benchmark. Reports: `compatible-packaged.json`, `managed-packaged.json`. The separately built SwiftPM owner also passed both modes (`compatible-final.json`, `managed-final.json`).

## What these checks establish

- Unit/integration tests cover durable namespace operations, dirty data preservation, current-generation cache integrity, request replay, managed publication dependencies, encryption/tamper/recovery, fixed upload budgets and UI state/routing.
- Subprocess qualification uses generated local remote fixtures, kills/restarts the actual owner process, and checks identity, open handles, rename publication, detached shutdown and recovered bytes. Twenty-five repeated renames provide a tiny-fixture latency distribution; they are not a large-drive or mounted Finder benchmark.
- App, FinderSync and FSKit compilation establish that the sources build against the installed SDK. Packaged FinderSync is optional and still needs macOS enablement and actual selection/URL delivery checks.
- A search-panel render test requires an unlocked interactive desktop to verify keyboard focus. When the frontmost app is `com.apple.loginwindow`, the test explicitly skips instead of treating visible-but-unfocused rendering as a product failure or a successful focus test.

## Remaining qualification gates

1. Matching Apple FSKit-capable provisioning profile, signed embedding, activation and actual mounted Finder callbacks. The available profile inventory did not provide this prerequisite; the packaged candidate does not include the FSKit module.
2. Live R2 conditional semantics and unknown-outcome recovery with isolated disposable remote fixtures. Synthetic success does not establish provider behavior.
3. Installed-app cold-launch Finder URL delivery, enabled FinderSync menus, cross-app search focus on an unlocked desktop, offline pinning, sleep/wake and editor save patterns.
4. Sustained large-file/mixed workloads, memory/disk bounds and latency under contention. Existing admission limits are not measured million-node or 100-GiB performance evidence.
5. Independent cryptographic review before presenting experimental encrypted managed storage as production-qualified. Local cache/staging/metadata remain plaintext; key rotation, provider rollback protection and encrypted server export are not implemented.

The changes are not an assertion of exact Helumi equivalence, notarized distribution or production readiness. See the implementation report for functional limitations including retained-trash cleanup, unsupported filesystem operations and adaptive bandwidth policy.
