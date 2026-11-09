# Finder moves: implementation and verification

## November 6, 2026 · installed build 32 and busy eject

With signed build 32 running against the personal R2 drive, a read-only directory handle and a process working directory held the volume open. A normal unmount returned Resource busy. Twenty observations over twenty seconds found the same application, authenticated worker PID, session, kernel mount and recovery record. Finder enumerated the volume both before and after the holder closed. The move and upload queues were idle at both ends. This checks session survival. The test does not observe macOS warning windows. Reproduce with `scripts/qualify-busy-eject.py --exercise-busy-eject --expected-build 32 --report <local-report-path>` against an idle drive.

Four isolated mounted lifecycle tests also passed, covering an app-initiated busy eject, a successful external eject, relaunch after external eject and a detached move that still needed recovery.

## November 6, 2026 · concurrent Finder moves on R2

On signed build 31, a native mounted rename and a CloudDrive background move ran simultaneously into the same generated R2 folder. Independent provider reads verified SHA-256 for 14 payloads, 14 nested metadata files and three folder metadata files. Both source folder companions disappeared from their old paths, both moved companions matched the originals, and the destination parent retained its own metadata. Finder read the test item in 0.719 seconds and resolved the volume again after publication.

The mounted slow-provider test also held the first copy open while a second protected move completed into the same parent. A second ordinary POSIX rename into that parent waited in macOS until the first resumed. For overlapping moves into T5 Backup, submit each with **Move to Folder…**. Fault injection covered an occupied destination, an interrupted copy, a worker restart, a stalled metadata read and a failed local completion record.

Date: 2026-11-04. **The signed `.6` build 20 is activated and live Finder eject succeeded. All 265 packaged Swift tests and 13 signed native checks passed.** The `.4` build's scoped signed qualification is historical evidence. A later real Photos move retained an incomplete journal; no successful completion of that large live workload is claimed.

## `.6` correction and qualification

Inactive retained moves previously returned busy for affected paths and blocked native mutations, producing an endless NFS JUKEBOX loop even though no background task could make progress. The `.6` backend returns terminal I/O errors for inactive pending/load-error state and preserves those errors through LOOKUP, GETATTR, directory reads and dispatch. Active work remains retryable. Path checks load retained state before answering. No recovery records are discarded and unresolved mutations remain blocked.

The previous live Finder directory FD was released by normal Finder Quit through Activity Monitor. Normal unmount returned zero. After authenticated upload-idle and move-inactive checks, SIGTERM was sent to the owned `.4` worker and its exit was confirmed. Journals, cache and ownership records remain retained, with private diagnostic backup. The replacement `.6` worker is now authenticated and running. Finder is detached; the accepted Photos move remains inactive and awaits explicit Resume. This controlled later shutdown does not establish the cause of the earlier disappearance of original PID 80830.

| `.6` check | Evidence | Status |
| --- | --- | --- |
| Backend race suites | `build/finder-moves/eject-terminal-backend-build.log` | Entire go-nfs module and touched rclone `vfs`, `cmd/serve/nfs`, `vfs/vfscache` passed. Includes timestamp proof, v1 receipt compatibility and terminal pending/load-error regressions. |
| Signed package and build identity | `build/finder-moves/eject-terminal-packaged-codesign.log`, `eject-terminal-packaged-buildinfo.log` | Strict codesign and all 75 recorded source hashes passed; app 0.5.7 build 20. |
| Signed native S3/slow-service qualification | `build/finder-moves/eject-terminal-packaged-native.log` | All 13 checks passed, including inactive recovery returning terminal EIO within three seconds, unrelated reads and normal unmount. Inventory/copy probes took 0.002–0.024 seconds. Actual Finder automation was not run in this harness invocation. |
| Full signed packaged Swift suite | `build/finder-moves/eject-terminal-packaged-swift-quiet.log` | Final quiet run: 265 tests passed, 0 failures, in 124.976 seconds. The initial run (`eject-terminal-packaged-swift.log`) had one window-focus assertion failure during live UI interaction/lock; the isolated focus test and quiet full rerun both passed without source changes. |
| Live activation and eject | `build/finder-moves/live-diagnostics/eject-terminal-activation.json` | Staged worker digest matches signed backend. Normal eject succeeded after Finder windows were closed; authenticated worker retained. An earlier busy OS handle prevented unmount and was reported without forcing it. |
| Real Photos recovery/completion | Same private activation summary | 8,700 inventory objects, four copy receipts, zero source-deletion receipts. Move was neither resumed nor completed as a qualification fixture. UI exposes Resume move. |

Artifact SHA-256 identities:

- Signed bundled/staged backend: `c12014ba511b61a3a12982739c839dcda9ff95aa73b2a7dca0fb1450c26eca15`.
- Unsigned `build/finder-moves/eject-terminal-backend/rclone`: `4ae73aada552b7a8c1f765a778be0b08691cbd053635ccf49eb07f7fbea5ac8a`.
- Matching `backend-source.tar.gz`: `e7767d3f4013568dac93e022e8b86ee76bcebfc3524ad0917b4ddd1117015f27`.

Notices bind the unsigned backend and archive: 440 files across 267 libraries. The default `build/backend` artifacts now match this `.6` source build; previous `.4`/`.5` generated artifacts were preserved. This is locally signed, not a notarized or published release. The new local namespace/FSKit architecture in `HELUMI_FILE_MANAGEMENT_IMPLEMENTATION_PLAN.md` is proposed work; these legacy fixes do not implement instant local rename acknowledgement.

## Historical `.5` correction and qualification

Read-only inspection of the retained `.4` live journal found 8,700 inventory objects, four copy receipts and zero source-deletion receipts. Rejected copied objects had destination timestamps about 39,000 seconds later than the original source timestamp; source timestamps and sizes still matched the inventory. This exposes an incorrect source/destination timestamp equality assumption when S3 uses LastModified. It is not evidence of deleted sources or completed recovery. The original worker PID 80830 no longer exists. No matching diagnostic crash report was found; its exit cause is unknown.

The candidate records the destination's observed timestamp in its synced copy proof, retaining original source identity separately. Recovery rechecks that destination proof before source deletion. Older v1 receipts without the optional destination timestamp retain the original source-timestamp expectation. Full-copy/verification-before-delete ordering and retained recovery records remain unchanged.

Finder eject now detaches the volume and returns control while healthy cloud work continues. It has no 30-second healthy-work deadline. Fresh authenticated upload and move checks, mount absence, session/generation validation and serialized operations gate automatic owned-worker shutdown. Active, unknown or failed work retains the process and records. Recovery continues monitoring a verified detached worker. Healthy detached work does not receive an unconditional recovery warning; actual errors and explicit Resume move remain visible.

| Historical `.5` check | Evidence | Status |
| --- | --- | --- |
| Native lifecycle suite | `build/finder-moves/detached-eject-lifecycle.log` | 21 tests passed, 0 failures, in 107.085 seconds. Includes active healthy work beyond 30 seconds, unknown status retaining the worker, and throttled upload fast-detach followed by automatic shutdown. |
| Full signed packaged Swift suite | `build/finder-moves/detached-packaged-swift.log` | 265 tests passed, 0 failures, in 124.975 seconds. |
| Backend timestamp proof and legacy receipt qualification | Final logs to be recorded after qualification. | Pending final evidence. |
| Signed `.5` packaging | `build/finder-moves/detached-packaged-codesign.log`, `detached-packaged-buildinfo.log` | Historical signed candidate used for the tests above; superseded by `.6`. No final `.6` identity is claimed here. |
| Signed native S3/Finder and slow-service qualification | `build/finder-moves/detached-packaged-native.log` | All 12 scoped checks passed; probe times 0.002–0.025 seconds. |
| `.5` activation and real Photos recovery/completion | Superseded before activation by `.6`. | Not performed; no successful live recovery or completion claimed. |

## Historical `.4` follow-up: observed live failure

A real Photos move on `.3` remained at Preparing and did not finish as expected. The active worker remained alive, and no matching crash report was found. An authenticated live pprof trace showed serialized S3 modification-time/HEAD fetches inside the directory-walk callback while its coordinator mutex was held. The long move namespace gate also held up NFS metadata requests. The trace identified blocking metadata work.

A read-only local index indicated approximately 8,700 files and 71 GB under Photos. That count did not read or modify the source payloads. It is workload context, not evidence that a move or copy completed.

## Historical `.4` implementation and acceptance evidence

- `RenameNative` starts one tracked backend job and returns `NFS3ERR_JUKEBOX` while it runs. Success is acknowledged after remote work and the final namespace/handle commit. Source/destination paths are guarded. Existing unrelated directory handles and an independent native mount stay responsive in the scoped development test; native writes return busy promptly. macOS may still block traversal through the rename parent on the same mount.
- The inventory walk collects keys without fetching per-object metadata under the walk coordinator mutex. Up to eight metadata workers prepare sizes, times and available hashes, with discovery/preparation counts exposed through move status.
- Up to four copy workers complete server-side copy and synced receipts, then a complete verification pass finishes before up to four deletion workers are admitted. Existing journal/recovery and source/destination identity checks remain required.
- Request groups are bounded individually: 30 seconds for directory listing/metadata and five minutes per copy operation. There is no whole-folder ten-minute deadline.
- The namespace/handle lock covers the short final commit rather than the remote inventory and copy duration. This does not make a folder move an atomic provider transaction or establish rollback on Finder cancellation.
- Native tests caught and corrected a committed-rename retry returning I/O failure when macOS changed the RPC transaction ID. Bounded recent-success history (256 entries), invalidated by source recreation rather than unrelated destination metadata writes, correlates those retries without suppressing a new source move. Permanent metadata failures reach the caller as terminal errors instead of producing endless retry replies; a new attempt can retry after the cause is corrected.

| `.4` check | Historical evidence | Status |
| --- | --- | --- |
| Live investigation | Authenticated worker trace plus read-only local index, as recorded above. | Diagnosis obtained; no source payload read or changed for the count. |
| Delayed native S3 inventory/copy responsiveness, final signed backend | `build/finder-moves/responsive-packaged-native.log` | Passed all 12 harness checks for 64 objects; the scoped read/list probes remained within the three-second bound in both phases. Signed backend hash matches the artifact below. |
| Same-mount parent traversal | Initial failed probe preserved in `build/finder-moves/responsiveness-native.log`. | macOS rename-parent vnode locking can still make parent-path traversal wait. The scoped pass does not prove all same-mount Finder browsing stays responsive. |
| Backend race suites | `build/finder-moves/responsive-go-tests-final.log`, `build/finder-moves/responsive-nfs-tests-final.log` | Entire `vfs`, `cmd/serve/nfs`, `vfs/vfscache`, and go-nfs module tests passed with race detection. |
| Full packaged Swift suite | `build/finder-moves/responsive-packaged-swift.log`; prior failure retained in `responsive-packaged-swift-before-catalog-fix.log`. | 259 tests passed, 0 failures, in 92.240 seconds (92.272 seconds suite wall time) against the final signed bundle. |
| Signed `.4` artifact and provenance | `build/CloudDrive-Moves.app`; verified upstream/patch source at `build/finder-moves/responsive-final-source`; unsigned backend, source archive and notices at `build/finder-moves/responsive-final-backend`. | Built and signed; codesign and recorded source/backend hashes verified. At activation, the staged worker digest matched the signed bundle. |
| Live R2 connection and activation | Normal safe-eject of the old app, old app quit, exact signed build relaunched; authenticated worker record/control PID, executable digest, CLI version and native mount checked. | `.4` served the original app mount at activation. R2 connection/listing checks passed; at that check uploads queued/in-progress/errors were all zero, move state idle and recovery false. Visible UI settled at “Finder browsing connected” with no Finder uploads waiting. This is connection/mount proof, not a completed Photos move. |
| Real Photos/R2 completion on `.4` | Later inspection found a retained 8,700-object journal, four copy receipts and zero source-deletion receipts; see `.5` diagnosis above. | Not completed; recovery remains unresolved. |

The final signed slow-service test independently paused inventory and copy, while the move remained active. Its scoped results were:

| Probe | Inventory pause | Copy pause |
| --- | --- | --- |
| Stat/read/list using a pre-opened unrelated directory FD | 0.005 s | 0.002 s |
| Root and unrelated-folder access through an independent read-only native mount | 0.028 s | 0.026 s |

The workload used 64 generated objects, 5 ms synthetic metadata delay and 20 ms synthetic copy delay. It also completed the move without payload download or unrelated changes, retained both copies after a denied delete, and recovered explicitly after a worker crash/restart. The harness reported success and its signed backend hash matched the bundle. Its HTTP fixture also logged a client-disconnect `BrokenPipeError` before the successful result; the log is not presented as error-free. The full packaged Swift rerun passed, as recorded above. It does not establish performance for the approximately 8,700-file live Photos tree.

The prior Swift run had one catalog assertion failure because the fixture could finish its automatic baseline before binding the authenticated worker-feed session. That later binding correctly requested another startup reconciliation, and slower native retry timing exposed the extra scan. The test now binds the feed before enabling the baseline and isolates periodic reconciliation with a one-hour test interval. Its exact assertion that ordinary file changes avoid a full-drive scan remains unchanged. The focused test passed in 24.314 seconds, followed by the successful full 259-test packaged rerun. No production change or repackaging was needed for this test correction.

## Historical `.4` artifact identity

Backend `v1.75.2-clouddrive.4` is packaged in app 0.5.7, build 18. This is a locally signed build, not a notarized or published release. Signing changes executable bytes, so the signed and unsigned hashes intentionally differ.

| Artifact | SHA-256 |
| --- | --- |
| Signed bundled `rclone` | `36cda377f55300ddb7d38beb5cb1e129aa7b1ba983f878b3271a06b3aca5ca47` |
| Unsigned `responsive-final-backend/rclone` | `392a1ed38cbd6745af4801526d1462446365ababf2baf295b23bb584ae620f8b` |
| Matching `backend-source.tar.gz` | `75845966367f9ad5b3c50862fc1f6753a7311b64dcb027a36eafc439db8cc7c9` |

The adjacent notices manifest binds the unsigned backend and source archive. The bundle's `BuildInfo.json` records the signed backend hash. Historical `.3` hashes below identify a different executable and must not be used to identify this build.

## Historical `.3` qualification

Historical `.3` backend: `v1.75.2-clouddrive.3` (rclone v1.75.2, go-nfs v0.0.4, Go 1.27.3). The checks below passed for that candidate, but did not establish large live-folder responsiveness.

The `.3` candidate was packaged as `build/CloudDrive-Moves.app` (app 0.5.7, build 18), signed with the configured stable certificate. It was not notarized or published. During its isolated qualification, the user's previous mount was left untouched. The later real Photos attempt on `.3` is the follow-up failure described above; `.3` fixture success must not be presented as proof that this workflow succeeded.

## Historical `.3` implementation

- Native rename preserves moved handles, rebases cached descendants, invalidates replaced destination identities, and preserves cached VFS child nodes. Handle lookup touches cached ancestors instead of scanning the entire handle cache. Native request leases coordinate handle resolution with namespace changes; failed SETATTR operations close their leased handles.
- Remote moves persist a destination-bound manifest and synced copy/delete receipts. They copy and verify the full inventory before deleting sources. Partial failure retains records for explicit authenticated recovery; multipart ETags are not treated as whole-file MD5.
- Busy source/destination cache data defers moves. Invalid subtree moves and incompatible/nonempty directory replacements are rejected. Completed rename replay, torn final receipt writes, failed inventory persistence, source/destination changes, and cache cleanup during a move have regression coverage. Inventory-persistence failure blocks further mutation until explicit resume can persist the inventory.
- The app reports move state separately from uploads and offers **Resume move**. Retained records block a direct writer. Eject checks move state as well as upload state and retains an unresolved worker.

The maintained changes are `vendor/patches/0004-go-nfs-rename-handles.patch`, `0005-rclone-safe-moves.patch`, the Swift move model/controller/presentation changes, build registration and qualification fixtures. All five patches apply cleanly to checksum-verified upstream archives in `build/finder-moves/reviewed-source`; patch hashes are pinned in `vendor/RCLONE_BUILD.json`. Independent review found the SETATTR lease and inventory-persistence error cases; both were fixed and independently rechecked before this final candidate.

## Historical `.3` verification results

| Check | Observed result | Evidence |
| --- | --- | --- |
| Added native lifecycle regression | Passed: an incomplete journal blocks direct uploads, permits Finder recovery, and keeps the owned worker/record when eject encounters unresolved move state. | `build/finder-moves/move-lifecycle.log` |
| Full packaged Swift suite | 259 tests passed, 0 failures, in 72.268 seconds against the corrected signed bundle. | `build/finder-moves/agent-swift-tests-final.log` |
| Entire go-nfs module with race detector | Passed, including helper tests and rename-handle concurrency coverage. | `build/finder-moves/go-nfs-all.log` |
| Entire touched rclone packages with race detector | `vfs`, `cmd/serve/nfs`, and `vfs/vfscache` passed. This is not a claim that every rclone package was tested. | `build/finder-moves/rclone-all.log` |
| Reviewed error-path regressions | SETATTR lease regression failed before its fix and passes in the full go-nfs suite. Inventory-persistence failure regression passes. | `build/finder-moves/setattr-before.log`, `build/finder-moves/persistence-test.log` |
| Signing/packaging Python tests | 21 tests passed. | `build/finder-moves/signing-tests.log` |
| Signed bundle checks | `codesign --verify --deep --strict` passed again after the reviewed fixes; the bundled backend and recorded workspace source hashes match `BuildInfo.json`. | `build/finder-moves/agent-codesign-final.log`, `build/CloudDrive-Moves.app/Contents/Resources/BuildInfo.json` |
| Native Finder and S3 fault fixture using the signed bundled backend | All eight checks below passed against the corrected bundle and matching signed backend hash. | `build/finder-moves/native-packaged-reviewed.log` |

The native packaged run used:

```sh
python3 scripts/qualify-finder-moves.py \
  --backend build/CloudDrive-Moves.app/Contents/Resources/rclone --s3 --finder
```

It verified cross-parent folder and file moves; open descendant file/directory handle continuity; an unrelated destination sibling remaining intact; Finder itself moving two generated folders; server-side copy and multipart copy without downloading the uncached move payloads; a denied source delete retaining both copies; authenticated recovery completing the move; and a deliberately killed synthetic worker being restarted and discovering/resuming its durable records. The fixture uses loopback services and synthetic credentials, not a saved R2 connection.

## Historical `.3` artifact identity

Signing changes the executable's bytes, so the signed and unsigned backend hashes differ intentionally.

| Artifact | SHA-256 |
| --- | --- |
| Signed bundled `rclone` | `7e207dabc23b1837ea25147d897d71ffd82bebd5e5287bc7a7cf56b7199528b3` |
| Unsigned `build/finder-moves/reviewed-backend/rclone` | `f8adbc4e754eabdefe75c87356eb823d3ce0605d733f20acfc04cf7b287cb143` |
| Matching `backend-source.tar.gz` | `662f79b0a389fc9e7bcab73a1da6817b940c637620b7165b60d81fa78fc1203d` |

The corresponding source and notices are adjacent to the unsigned backend. Their manifest binds the unsigned executable and source archive. The signed bundle's `BuildInfo.json` records its signed backend hash.

## Shared boundaries and activation

A successful live Photos/R2 move remains unverified, including recovery with the pending `.6` candidate. The historical `.3` results establish small local/native Finder fixtures, signed-resource behavior and tested recovery cases, while the later live failure demonstrates that they were insufficient to qualify large-folder responsiveness.

Moves remain multi-step remote workflows, not atomic folder transactions. The `.4` inventory limits remain 10,000 objects, 10,000 directories and a 32 MiB manifest. The `.3` whole-folder ten-minute deadline is superseded by `.4` per-request bounds: 30 seconds for listing/metadata request groups and five minutes for each copy operation. The `.4` job returns a retry response during remote work and limits the namespace/handle lock to the final commit. The scoped probes above establish backend responsiveness during pauses; traversal through the same-mount rename parent can still wait inside macOS. Concurrent external writers, cross-volume move semantics, cancellation rollback, and long-duration provider failure matrices are not established by these checks. Where no comparable checksum is available, successful copy receipts plus size/modification metadata do not constitute independent cryptographic content verification.

The `.4` build was activated through the normal app safe-eject/quit/relaunch path, and its staged worker digest and authenticated PID were verified against the signed build. The original Photos move was not replayed and no user file-content operations were performed during activation. After the transient startup status, the visible app settled at “Finder browsing connected — No Finder uploads waiting. Use Upload directly to avoid local staging.” For future builds, safely eject and quit the current app before reconnecting: workers are staged outside the bundle, so rebuilding alone does not replace an existing mount. Preserve any pending cache and move records. See [Finder move behavior](FINDER_MOVES.md) and the [implementation plan](FINDER_MOVES_IMPLEMENTATION_PLAN.md).
