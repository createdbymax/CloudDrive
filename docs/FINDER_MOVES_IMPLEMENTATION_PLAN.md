# Reliable moves within the Finder drive

Date: 2026-11-04. Status: `.6` signed build 20 activated; native qualification and live eject passed. All 265 packaged Swift tests and 13 signed native checks passed. The signed `.5` candidate passed 265 Swift tests and 12 scoped native harness checks before the inactive-recovery retry issue was corrected. See [behavior](FINDER_MOVES.md) and [verification](FINDER_MOVES_VERIFICATION.md). Historical `.4` passed scoped signed tests and was activated, but the subsequent live Photos move retained an incomplete journal. No successful large live Photos move is claimed.

## Follow-up: inactive retained moves must stop retrying

The `.6` correction distinguishes active work from an inactive retained failure. Active affected paths and mutations remain retryable; inactive pending moves and corrupt/foreign records return terminal I/O errors. LOOKUP, GETATTR, directory reads and dispatch preserve that terminal outcome instead of converting it to endless JUKEBOX or hiding it as a missing path. Reads load retained records before deciding whether a path is guarded. This changes error reporting, not the recovery journal or permission to mutate: unresolved work remains blocked until explicit recovery.

Live shutdown was completed through normal Finder Quit (releasing its sole directory FD), normal unmount with exit status zero, and authenticated idle/inactive worker checks followed by SIGTERM and confirmed exit. Journals, cache and ownership records were retained, with private diagnostic backup. The authenticated `.6` worker is now active with Finder ejected; Photos remains retained for explicit Resume.

## Historical `.5` follow-up: destination timestamp proof and detached eject

Read-only inspection of the `.4` live record found 8,700 inventory objects, four copy receipts and zero source-deletion receipts. Rejected copied objects had destination timestamps about 39,000 seconds later than the source snapshot while source timestamps and sizes still matched. S3 objects without custom mtime can acquire a new LastModified during copy; comparing that new destination timestamp to the original source incorrectly rejects a valid copy. The original worker PID 80830 was later absent. No matching diagnostic crash report was found, and the cause of its exit is unknown.

The `.5` correction records the destination's observed timestamp alongside its verified checksum in the synced copy receipt. Source checks continue using the original source snapshot; destination checks use the recorded copy identity before any source deletion. Optional timestamp fields preserve v1 compatibility: older verified receipts retain their original source-timestamp expectation. The complete-copy/verification barrier remains required.

Eject now separates successful Finder detach from background cloud-work completion. It returns control after detach, reports healthy outstanding work, monitors verified detached workers after recovery, and automatically stops the owned worker only after fresh authenticated upload-idle and move-safe checks. There is no 30-second healthy-work failure. Active, unknown or failed work retains the worker and records, with explicit move recovery available. Session/generation checks and serialized operations prevent a stale progress sample from authorizing shutdown.

The 21 native lifecycle tests passed in 107.085 seconds, including a healthy active move beyond 30 seconds, unknown status retaining the worker, and throttled uploads continuing after fast detach before automatic shutdown. The signed `.5` candidate subsequently passed all 265 Swift tests in 124.975 seconds and all 12 scoped native harness checks, with probe times from 0.002 to 0.025 seconds. These are historical `.5` results; current `.6` evidence and the final quiet Swift rerun are recorded in the verification report.

## Historical `.4` follow-up: large-folder preparation and responsiveness

The live `.3` worker remained alive during the reported Photos failure, and no crash report was found. An authenticated pprof trace showed serialized S3 modification-time/HEAD work inside the directory-walk callback while its coordinator mutex was held. The move's namespace gate also blocked NFS metadata requests. A read-only local index counted approximately 8,700 files and 71 GB under Photos; no source content was read or changed for that count.

The `.4` correction implements:

- Start one tracked native rename job and return `NFS3ERR_JUKEBOX` while the client waits/retries. Keep the source/destination paths guarded, and acknowledge success only after the final namespace and handle commit. Return busy promptly for native writes rather than making them wait behind remote work.
- Keep unrelated server requests available while remote inventory or copy is delayed. Hold the global namespace/handle lock only for the short final commit. Use existing unrelated directory handles and an independent native mount to separate server responsiveness from macOS rename-parent vnode locking; traversal through the same-mount parent can still wait.
- Collect keys in the walk callback, then fetch metadata with eight bounded workers outside that callback. Report discovery/preparation counts so long preparation is observable.
- Use four copy workers, a full copy/receipt and verification barrier, then four deletion workers. Preserve the existing journal, receipt, source-identity and recovery guarantees.
- Bound listing/metadata request groups to 30 seconds and each copy operation to five minutes. Remove the whole-folder ten-minute deadline; a large healthy folder must not fail solely because total work exceeds that duration.

Required regression: independently pause inventory and copy in the loopback S3 fixture. In each phase, complete unrelated stat/read/list through a pre-opened directory handle and root/other-folder access through a second read-only native mount within three seconds. Preserve the initially failed same-mount parent-path probe as evidence of the macOS rename-parent vnode constraint, rather than claiming all browsing is unblocked. Also verify affected paths remain guarded, writes fail busy promptly, progress advances, and failures preserve recoverable data. The final signed `.4` scoped test passed, and its artifact identities and full-suite results are recorded separately in the verification report. A successful live `.4` Photos/R2 move remains a separate qualification step.

## Outcome

Dragging files or folders between directories in the same mounted CloudDrive volume, renaming them, and using Finder's Move Item Here should complete reliably. Existing open handles must continue to identify the correct objects. Failures must preserve recoverable data, expose their actual outcome, and never leave the app claiming that an unresolved move is finished.

The reported symptom is Finder remaining at “Preparing to move 2 items” to “T5 Backup.” That screenshot establishes a waiting operation, but does not identify the blocking NFS procedure or establish that a RENAME request was sent. “T5 Backup” could be the destination folder name; first confirm both source and destination belong to the same mounted filesystem. Cross-volume moves are copy/delete workflows and require separate qualification.

## Original pre-change findings

| Finding | Evidence | Implication |
| --- | --- | --- |
| Moves already have a backend implementation. | `Sources/CloudDrive/Drive.swift:314` launches rclone `serve nfs`; rclone `cmd/serve/nfs/filesystem.go`, `FS.Rename`, delegates to `VFS.Rename`; `vfs/vfs.go:650` delegates to `Dir.Rename`. | Adding a Swift drag/drop handler will not repair native Finder operations. |
| R2 moves take the object-storage copy/delete path. | Pinned rclone `backend/s3/s3.go` implements `Copy`, but no `Move` or `DirMove`; `fs/operations/operations.go`, `move`, copies before deleting the source. | Same-volume moves are remote work, even when no payload download is needed. They cannot be assumed instantaneous or atomic. |
| Folder moves synchronously enumerate and move remote objects. | `vfs/dir.go:1201`, `Dir.Rename`, calls `operations.DirMove`; that fallback loads the remote tree, creates destination directories, moves objects using checker concurrency, then removes source directories. | Folder size, listing latency, retry behavior and partial remote failures matter. This path is materially different from moving a local directory. |
| Long operations hold up requests on the same NFS TCP connection. | go-nfs `conn.go`, `conn.serve`, invokes `handle` synchronously; `nfs_onrename.go` waits for `fs.Rename` before returning. VFS rename uses `vfs.ctx`, rather than a request-scoped context. | A slow remote move can also stall metadata operations on that connection. A Swift control API timeout does not cancel this operation. |
| Rename invalidates only the moved item's old handle. | go-nfs `nfs_onrename.go:90` calls `InvalidateHandle`; `helpers/cachinghandler.go:145` removes exactly that UUID. The default rclone memory cache delegates to this handler through `cmd/serve/nfs/cache.go`. Cached descendant entries retain old path arrays. | There is a concrete handle-coherence gap: moved-item handles become stale, and descendants can still resolve to old paths. Its role in this Finder stall needs reproduction. |
| Dirty files and directory moves need dedicated validation. | `vfs/file.go`, `File.rename`, handles writer/cache state; `vfs/dir.go`, `Dir.rename`, updates directory nodes and calls `vfscache.DirRename` after the remote tree move. Cache rename failures are logged. | Moving a published tree is not proof that a tree with queued, open or uploading files is safe. |
| The app primarily reports uploads, not moves. | `Drive.sampleProgress` reads `vfs/queue` and `core/stats`; `UploadProgress.swift`, `TransferStats`, decodes `transferring`, not `checking`. rclone `operations.Move` uses `NewCheckingTransfer`. `Drive.eject` drains `diskCache.idle`. | A server-side move may have no upload row. Move activity and shutdown safety need explicit coverage rather than treating an empty upload queue as sufficient. Normal unmount remains the first gate. |
| Search has rename invalidations already. | `vendor/patches/0003-rclone-metadata-changes.patch` emits old/new paths and recursive directory hints. `CatalogChanges.swift` reconciles metadata independently. | Preserve these hints, including after partial failures. A hint is not a successful move receipt. |

Backend source above was inspected in `build/license-work/rclone` and `build/license-work/go-nfs`, the locally available source snapshots matching the declared upstream versions. These are generated build inputs, not maintained product source. Changes must be delivered as reviewed patches in `vendor/patches/` and applied by the build script. The declared bases are rclone v1.75.2 and go-nfs v0.0.4 in `vendor/RCLONE_BUILD.json`.

### Original investigation verification

Ran:

```sh
swift test --filter DriveLifecycleTests/testFinderChangesAutomaticallyUpdateSearchWithoutCatalogRefresh
```

Result: **1 test passed, 0 failures**, test duration 8.477 seconds. It mounts a disposable local backend, copies a file, renames the file, renames a folder containing a published file, and checks automatic catalog updates. Its temporary mount was gone afterward. It does not exercise Finder UI, cross-parent folder moves, retained descendant handles, or real R2 copy/delete behavior.

`scripts/qualify-local.py` also contains file rename/replacement coverage, but was not run for this investigation. Neither that script nor the focused test proves the reported operation works.

At the original inspection, build identity also needed attention: the `build/backend/rclone` SHA-256 is `437c03e393261859f7af437c28d106a0888d4c48cb7b98615fc6d4ebcc50411b`; `build/CloudDrive.app/Contents/Resources/rclone` is `4c409c47b3e4fef22c8c7c796e41fced9532c4ea0ec39dfe69c2644b6f42cd4a`. They differ. The running worker's binary was not inspected. `Drive` intentionally stages workers outside the bundle, so rebuilding alone does not upgrade an existing mount.

No operations were performed on the user's mounted files, connection or R2 objects. The exact cause of the screenshot is **unconfirmed**; the findings above define the first reproducible tests and fix boundaries.

## Implementation sequence

### 1. Reproduce and locate the wait

Add `scripts/qualify-finder-moves.py` using the private fixture, bounded subprocess and retain-on-failure conventions in `scripts/qualify-local.py`. Keep mounted I/O outside the app and harness process. Do not recursively inspect a stalled mount. Start with the exact packaged backend and record its digest, effective mount options and fixture configuration.

Run separate cases for same-parent rename, cross-parent move, nested folder move and the two-item Finder operation. Test both a local backend and an isolated S3-compatible fixture that actually exercises `CopyObject`, multipart copy, paginated listing and delete. Use the existing synthetic HTTP fixture patterns in `scripts/fixtures/` where practical; a local filesystem backend alone is insufficient.

Capture bounded private backend diagnostics for operation start/end, NFS procedure, RPC transaction ID, relative source/destination, phase and elapsed time. Determine whether Finder is blocked on LOOKUP/GETATTR/READDIRPLUS/ACCESS before rename, on the rename itself, or on follow-up metadata. Simulate delayed listing/copy/delete and record whether unrelated metadata requests stall. Avoid raw HTTP authorization, environment dumps and user filenames in exported reports. Existing worker stderr goes to `/dev/null`; diagnostic capture needs a deliberate bounded fixture path before enabling product logs.

**Exit condition:** a failing regression with its last completed phase, or evidence that the observed installed worker differs from the tested backend. If the local fixture passes, continue to S3 and Finder rather than declaring the issue fixed.

### 2. Preserve NFS identity across rename

Add a focused go-nfs patch, provisionally `0004-go-nfs-rename-handles.patch`, and companion rclone integration changes if needed.

- Define an optional rename-aware handler operation that receives filesystem identity, old path and new path. Invoke it after a successful filesystem rename. Keep existing fallback behavior for handlers that do not implement it.
- Rebind the moved item's existing handle and all cached descendants to the destination using path-component boundaries. Preserve handles for the same objects; do not just invalidate the entire subtree. Test an open file and a retained child-directory handle after moving their parent.
- Update forward/reverse mappings consistently under an explicit locking strategy. Handle replacement of an existing destination without redirecting its old handles to unrelated source objects. Define no-op rename behavior.
- Forward the hook through rclone's `Handler` and `pathRewriter`, using canonical root-relative paths. Scope initial support to the app's default memory cache; either implement equivalent behavior for other cache modes or retain an explicit, tested fallback.
- Refresh/invalidate directory listing verifiers and return accurate source/destination weak cache consistency attributes. Map ordinary rename errors to appropriate NFS statuses rather than collapsing all failures to generic I/O.
- Test concurrent LOOKUP/READDIRPLUS/rename, prefix lookalikes (`Album` versus `Album2`), Unicode, replacement and eviction with the race detector. Check RPC retransmission behavior so a completed rename followed by a lost reply does not execute destructive work twice. macOS changes transaction IDs while retrying `JUKEBOX`; keep bounded recent-success history and invalidate a prior success when its source is recreated so a committed move does not later return spurious I/O failure or suppress new work.

**Exit condition:** protocol tests prove old handles still identify the moved objects, descendants resolve at their new paths, and overwritten destination handles never identify a different object.

### 3. Make remote moves safe and observable

The synchronous native rename used for the first `.3` fix is superseded by the `.4` follow-up above. Run one tracked backend move job, return the NFS retry response while it is unresolved, and acknowledge success only after remote completion and the namespace/handle commit. A background Swift queue alone cannot provide these Finder semantics.

- Validate self/descendant moves, source/destination types, collisions, same-path and case-only names before destructive work. Test file replacement, empty-directory replacement, nonempty-directory rejection and Finder's user-approved collision behavior. Do not silently merge folder trees merely because the object backend permits it.
- Serialize overlapping source/destination mutations. Include both prefixes for folder moves and coordinate with VFS writers, queued uploads, cache eviction and other renames. Preserve the existing rule that direct uploads require the Finder worker to be stopped.
- Initially reject/defer a folder move before remote mutation if its subtree has dirty/open/uploading files, with a recoverable, clearly surfaced result. Permit it only after tests prove cache, writer and remote state transition safely together. Recheck after acquiring the mutation guard.
- Retain server-side copy for supported same-bucket moves, including multipart copy for large objects. Verify the destination's expected size and available integrity evidence before deleting its source; do not treat a multipart ETag as a universal content hash. A copy failure must leave its source intact. A delete failure must report an unresolved/partial move, preserving both copies.
- For multi-object moves, persist a private destination-bound operation manifest before mutation, with per-object source identity, destination and copy/delete outcome. Reconcile uncertain copy/delete results after restart. Record sufficient evidence before source deletion; never remove an unexpected changed source. Current outside-writer support remains unchanged, and checks must not be advertised as cross-client atomicity.
- On a partial folder failure, retain the manifest, reconcile the VFS view with actual remote state, and emit invalidations for both prefixes. Avoid blind rollback or deleting the destination to “clean up.” Preserve originals of unrelated collision targets.
- Add request/phase deadlines and bounded retry policy where contexts can actually propagate. Timeouts mean an uncertain outcome requiring reconciliation, not permission to return success or start another conflicting move. Do not globally shorten NFS mount timeouts or use soft mounts as a data-safety fix.

**Exit condition:** delay, permission, lost-response, process-death and partial-delete tests preserve every accepted byte and provide deterministic recovery. No full local payload download is required for supported clean server-side moves.

### 4. Keep the drive responsive and lifecycle safe

Expose authenticated move state, separate from upload counters: preparing/listing, moving objects, verifying, removing old entries, completed, and needs recovery. Counts must reflect known totals; expose discovered/prepared counts while enumerating, with totals allowed to grow until inventory completes. Reuse bounded control decoding and destination/session binding patterns from `Runtime.swift` and `CatalogChanges.swift`. Keep status publication free of network work, and keep remote metadata fetches outside both the walk coordinator mutex and the short namespace/handle commit lock.

Show plain text such as “Moving 2 items” or “Move needs attention” in Transfers and the menu. Do not claim the app can update Finder's own progress dialog. Record a concise reason and next action for failures, and distinguish a copied destination from a completely removed source.

Include active/uncertain moves in worker termination, direct-mode switching, quit and update gates. Keep ordinary unmount and ownership validation. Finder detach may finish while accepted cloud work continues; do not impose a healthy-work drain deadline. Monitor the detached worker and stop it automatically only after fresh authenticated upload-idle and move-safe checks. Unknown or failed work retains the worker and records. Recovery must discover operation manifests before allowing a new writer and resume monitoring an adopted detached worker.

The live `.3` trace established that serialized preparation and a long namespace gate are user-visible bottlenecks. The `.4` implementation must use the tracked asynchronous native job and bounded request pools above, preserving retry/result correlation and the all-copy/verify barrier. Do not introduce unbounded per-request goroutines or claim that the destination is committed before the final namespace/handle transition. An instant namespace overlay remains a separate architecture project.

**Exit condition:** the app stays responsive during a delayed move, accurately reports its state, and cannot shut down or switch writers across unresolved mutations.

### 5. Integrate, package and qualify

Register patches in `scripts/build-rclone-allocation.py`, update patch hashes and the backend version in `vendor/RCLONE_BUILD.json`, include focused Go tests in the build, and update third-party notices/source packaging through `scripts/collect-backend-notices.py` and `vendor/THIRD_PARTY_CHANGES.md`. Preserve all existing allocation and metadata-feed patches.

Add native cases to `Tests/CloudDriveTests/DriveLifecycleTests.swift`, recovery/status tests, and recursive catalog tests in `AutomaticCatalogTests.swift`. Update `ARCHITECTURE.md`, `LIMITATIONS.md` and `VERIFICATION.md` with supported semantics and actual evidence.

Build and qualify a signed app through the existing packaging flow. Safely eject/drain the old worker before testing the new one, then verify the staged worker digest matches the intended packaged backend. Do not terminate the currently stuck user operation merely to activate a build.

## Required acceptance matrix

| Area | Cases and evidence |
| --- | --- |
| Native Finder | Drag file/folder between parents; Move Item Here; move two mixed items; rename in place; cancel during preparation. Capture actual Finder outcome and independently inspect remote keys. |
| Namespace | Root and nested paths; empty folder markers; deeply nested folders; spaces, accents, emoji and case-only names; same path; reject move into self/descendant; collision/replace behavior. |
| Handle continuity | Keep source, destination and descendant handles open across rename. Subsequent stat/read/readdir must address the same objects. No false stale handles or paths silently referring to replacement objects. |
| Cache/writes | Uncached and cached files; freshly copied file; folder with unpublished files; queued/active upload; open writer; clean eviction during move. Unsupported busy cases must fail before remote mutation. |
| Remote behavior | Paginated trees, many small objects, large multipart-copy object, slow copy/list/delete, 403/429/5xx, copy failure, delete failure and lost responses. During independent inventory and copy pauses, existing unrelated directory-FD stat/read/list and independent-mount root/folder access finish within three seconds. Same-mount rename-parent traversal may still wait in macOS. No source deletion before the full copy/verification barrier. |
| Restart/retry | Worker death before copy, after copy, during delete and between children; lost NFS response/retransmission; app restart; retained partial folder state; idempotent recovery. |
| App/catalog | Move progress without upload traffic; final old/new search paths; recursive partial-failure reconciliation; feed gaps; eject/quit/update/direct-mode gates; old-worker compatibility. |
| Regression | Existing allocation, upload, ownership/recovery and catalog tests pass against the packaged backend. Local fixture results and actual R2/Finder results are reported separately. |

Qualification order: focused Go and race tests → deterministic S3 fault fixture → isolated native NFS tests → signed packaged Finder tests → dedicated R2 test-prefix verification. Provider qualification must use generated fixtures, independently validate destination contents and source absence, and leave an actionable record for any retained partial move.

## Delivery boundaries

1. Reproduction and protocol/cache fix: demonstrate the failing case first, then pass it with the intended packaged backend.
2. Remote integrity/recovery and lifecycle protection: complete before declaring folder moves supported across failures.
3. Finder/R2 acceptance evidence and documentation: complete before release.

Do not make an unconditional “moves fixed” claim based only on the passing local rename test. The completion criterion is the reported Finder workflow working with the packaged worker, plus the failure/recovery guarantees above.
