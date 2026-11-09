# Helumi implementation verification

November 5, 2026. This records fresh local evidence, not live-bucket conversion or activated Finder proof. See `HELUMI_IMPLEMENTATION_PROGRESS.md` for unfinished implementation/qualification boundaries.

## Results

| Check | Result | Evidence |
|---|---|---|
| Full Swift suite | 397 passed: 285 app, 6 FSKit adapter, 106 core; zero failures | `build/helumi-all-final-tests.log` |
| Native S3 final focused suite | 19 passed, zero failures, including latest large-copy preflight | `build/s3-large-copy-preflight-tests.log` |
| Signing/packaging Python tests | 25 passed | `build/helumi-signing-current-tests.log` |
| 100,000-descendant rename | 3.470 ms; 18 SQLite changed rows | `NAMESPACE_100000_RENAME` in full-suite log |
| Owner lifecycle/backpressure | 20 passed; pause persistence, corrupt control, replay, active read/pin stop protection | `build/namespace-lifecycle-verification.log` |
| Snapshot discard | 36 passed; open-handle generations and pending dependencies retained; completed unlinked data reclaim uses separate discard proof | `build/discarded-gc-tests-final.log` |
| Migration/recovery/export | 13 passed; recognized FORMAT/foreign FORMAT, persisted inode restore, metadata-only import, restartable export | Full Swift suite |
| App lifecycle | 12 passed including independently observed Finder-eject absence reconciliation | Full Swift suite; mount table is injected for this test |
| Fresh standalone owner, compatible and managed | Five process-level checks per mode; import/admission, rename/handles/read, accepted writes across SIGKILL, unlink handles, sync/detach/stop | `build/helumi-native-{compatible,managed}-final.log` |
| Real FSKit extension build | Xcode build passed; unsigned, not activated | `build/fskit-final/build.log` |
| Source whitespace | `git diff --check` passed | `build/helumi-diff-check.log` |

The focused transport suite follows the full suite and adds one test. No separate full-suite rerun is claimed for that final test-only addition and explicit >5 GiB preflight guards.

## Candidate artifact

`build/CloudDrive-Instant.app`, version 0.6.0 build 21, is a separate inactive candidate. The legacy `CloudDrive-Moves.app` was preserved. Candidate app and owner are signed by the existing stable Apple Development identity (team EGEBBVL76D); `codesign --verify --deep --strict` passes. `Contents/Resources/BuildInfo.json` records executable digests and source hashes.

The exact packaged signed owner is also exercised in both generated-storage modes; final evidence is `build/helumi-packaged-compatible-final.log` and `build/helumi-packaged-managed-final.log`. Each must contain five passed checks and an engine SHA matching BuildInfo. These fixtures explicitly bypass production signed-peer enforcement only with a synthetic local storage configuration; they do not qualify real R2 credentials or Finder mounting.

The candidate intentionally contains no filesystem extension because no valid Apple FSKit profile is installed. Native mounting stays gated. The unsigned extension is available at `build/fskit-final/Products/Debug/CloudDriveFS.appex`. Do not install an ad-hoc substitute or turn a successful extension compile into an activation claim.

## Required next release evidence

1. Obtain an Apple provisioning profile for `local.bucketdrive.app.filesystem`, team EGEBBVL76D, with `com.apple.developer.fskit.fsmodule` and the pinned certificate. Repackage through the profile validator, then approve/activate in macOS and test real Finder move/edit/read/eject/restart with delayed network.
2. Qualify managed publication, lost replies, conditions and cold reads in a new isolated R2 prefix. Do not use Photos or convert the existing pending legacy drive.
3. Finish the sustained workload matrix and bound extent-manifest rewrite costs. Unit tests and one 100,000-node rename do not prove 100 GiB streaming/cache limits or power-loss recovery.
4. Qualify Finder refresh for owner-originated uploads. Optional FinderSync badges remain separate unfinished work.
5. Keep ordinary-key operations above 5 GiB blocked unless a safe publication protocol is implemented and independently verified. R2 multipart-copy source conditions and destination commit fencing cannot be inferred from successful small CopyObject tests.

No real Photos recovery was resumed or discarded as part of this qualification.
