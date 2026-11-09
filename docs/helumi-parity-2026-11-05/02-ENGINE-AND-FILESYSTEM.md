# Engine and filesystem development specification

Date: 2026-11-05. Scope: current working tree, including uncommitted implementation. This document proposes follow-up development; it changes no runtime behavior. Source inspection is current; test results below are records in the repository and were not rerun for this documentation task.

## 1. Outcome and evidence boundary

The desired experience is a local-feeling drive: rename, browse and save acknowledge durable local state promptly; remote publication, download and recovery have independent progress. This experience requires correct identities and storage ownership before animation or transfer presentation can conceal latency.

The previous [Helumi investigation](../HELUMI_FILE_MANAGEMENT_IMPLEMENTATION_PLAN.md#2-evidence-and-boundaries) records FSKit, stable `DriveNode` identity, local staging, ranged content, background scheduling, and an ID-based remote API. Those are historical artifact findings, not proof of every Helumi runtime behavior. Fresh target evidence belongs in this investigation's evidence ledger. In particular, Helumi's power-loss guarantees, conflict policy, remote storage layout, xattr behavior and exact throughput are unknown until independently observed. The implementation below is BucketDrive's design, not recovered Helumi source.

The fresh root investigation identifies Helumi **0.3.18 build 45**, with OrbitFS SHA-256 `ec9aa769087937afa289b9c70c9b468fd32eb035c959ea232c8c48b747cd40d0`. Its selected ARM64 symbols (retained locally) retain OrbitCore API, staging and scheduling names. REA plist evidence `ev_f81ddbafc846c5f6f2dc3f9559619b9930245a165d0dd9c3a2711c0d158ad762` establishes FSKit/path-resource declarations and a minimum OS of 26. These declarations/symbols do not establish execution order or runtime durability. Old 0.3.13 addresses and scheduler constants are historical only and must not be presented as current-build findings.

Do not restart the November 4 architecture project from scratch. Much of it now exists. The highest-value work is to qualify the native mount, close specific scale and scheduling gaps, and make supported filesystem semantics explicit.

## 2. Current implementation inventory

Paths below are repository-relative and identify owning symbols. A source implementation is not automatically a supported released feature.

| Capability | Current owning source | Assessment / next evidence |
|---|---|---|
| Stable file and volume identity | `Sources/CloudDriveCore/NamespaceModels.swift`: `NamespaceNode`, `NamespaceVolume`; `NamespaceStore.swift`: schema, `rename` | UUID plus persisted inode; local rename updates one node and parent revisions. Preserve this implementation. Measure through Finder, not only a store call. |
| Transactional namespace + journal | `NamespaceStore.swift`: `NamespaceDatabase`, `rename`, `commitContent`; `OperationJournal.swift` | SQLite DELETE journal, FULL synchronous and fullfsync settings; operation, dependency, receipt and event tables. Do not describe it as WAL. Filesystem/hardware durability still needs power-loss qualification. |
| Local content generations | `ContentStore.swift`: `ContentSnapshot`, `prepareWrite`; `SyncEngine.swift`: `writeValue`, `truncateValue` | Flushed immutable extents and checked snapshot manifests precede namespace commit. Flat extent arrays and accumulated generations require sustained scale testing. |
| Retained open-file bytes | `NamespaceOwner.swift`: peer-bound `ClientHandle`; `SyncEngine.swift`: `retain`, `release`, generation leases | Replacement/unlink preserves old content for handles; explicit published/discard proofs control reclamation. Qualify actual editor save patterns. |
| Read-through ranges | `RangeCache.swift`: `read`; `SyncEngine.swift`: `readValue` | Stable node/generation cache, checksum and provider validator checks, in-flight coalescing. Default chunk 1 MiB and cache 5 GiB are our source defaults, not measured optimum. |
| Offline pinning | `PinJournal.swift`; `RangeCache.swift`: `requestPin`; `SyncEngine.swift`: `pin`, pin runner | Durable intent and partial progress are separate from completed residency. Source supports recursive requests and future-child handling; offline runtime matrix remains. |
| Compatible ordinary keys | `SyncEngine.swift`: `processCompatible`, relocation manifests; `S3StorageRemote.swift`: `copy`, `remove` | Local overlay followed by copy/verify/conditional deletion; no atomic remote folder move. Provider qualification and >5 GiB safe publication remain gates. |
| Managed identity-based storage | `ManagedManifest.swift`: `ManagedManifestPublisher`; `SyncEngine.swift`: `processManaged`, `publishInitialNamespace` | Immutable content plus hash-trie metadata and conditional HEAD. A conflict must stop publication, not overwrite someone else's HEAD. Live transport evidence still required. |
| Recovery / interoperability | `NamespaceRecovery.swift`: `restoreManaged`; `NamespaceMigration.swift`; `NamespaceExport.swift`: `NamespaceExporter` | Explicit restore, checked checkpoints and ordinary-key export exist. Recovery currently materializes exported records; large-namespace recovery needs a bounded-memory design/measurement. |
| Native filesystem | `Sources/CloudDriveFS/CloudDriveFSVolume.swift`, `CloudDriveFileSystem.swift` | macOS 26 availability, RPC callbacks, stable items, bounded directory cookies, open/close/read/write. Compile and callback tests exist; signed activated Finder proof absent. |
| Owner process / IPC | `Sources/CloudDriveEngine/EngineMain.swift`; `NamespaceIPC.swift`; `NamespaceOwner.swift` | Authenticated peer identity, bounded frames/admission/replay, process separation. Keep one authoritative owner per volume. |
| Mount / detach lifecycle | `Sources/CloudDrive/NamespaceDriveController.swift`: `mount`, `eject`, `refresh`, `stopIfReady` | Owned mount validation, detach reconciliation and safe owner retirement exist. Verify independent Finder eject, sleep/wake and busy handles on real mount. |
| Search / UI routing | `NamespaceSearch.swift`; `NamespaceDriveController.swift`: `search`, `enqueue`; `NamespaceFileActions.swift` | Namespace route exists; avoid independent catalog writes for namespace volumes. Check event-to-Finder refresh and stale UI revision handling. |
| Remote execution fairness | `SyncEngine.swift`: `processPending` | One `processing` flag and sequential loop await each operation. Reserved RPC metadata capacity does not create independent remote upload lanes. Implement dependency-aware concurrency only after invariants are fixed in tests. |
| Desktop filesystem breadth | `CloudDriveFSVolume.swift`: capability declarations, link callbacks | Only files/directories; symbolic and hard links return ENOTSUP, maximum xattr size is zero, ownership/permissions restricted. Helumi equivalence is unknown; validate workflows and explicitly bound product support. |

Repository verification [records](../HELUMI_VERIFICATION.md) list 397 Swift passes, 25 packaging tests, native compatible/managed process fixtures and an unsigned FSKit build. The recorded 100,000-descendant rename is 3.470 ms with 18 changed SQLite rows. These are useful synthetic evidence, not a Finder or live R2 performance guarantee. The candidate is recorded as excluding the FSKit extension because a valid matching profile was unavailable.

## 3. Preserve these contracts

1. **Acknowledged means locally recoverable.** Reply only after payload and referenced metadata are durable. Cloud success is a separate state. A disk-full failure must leave the last accepted generation intact.
2. **Paths are presentation.** Stable IDs, open handles, pin identity, upload identity and cached generations survive same-volume rename. Derive paths from parents; do not rewrite descendants before acknowledgement.
3. **Local durability is not remote publication.** `synchronize(waitForCloud: false)` must remain a local barrier. A remote barrier captures a revision and cannot claim a later edit is uploaded because an earlier request finished.
4. **One owner admits changes.** Finder, app uploads, search actions and cleanup use the same owner. Preserve peer authentication, request fingerprints and durable replay; a different payload with the same operation ID is an error.
5. **Never reclaim the only accepted bytes.** Clean cache, dirty staging, retained generation data, and pinned content have different lifetimes. Unpin does not mean discard dirty bytes.
6. **Uncertain remote replies are reconciled.** A timed-out PUT/copy/delete/HEAD publication does not imply failure or permission to repeat destructively. Receipts and remote identity decide.
7. **Conflict is visible and non-destructive.** Preserve local accepted data; stop dependent work; do not silently force remote state or downgrade conditional requests.
8. **Modes are explicit.** Compatible mode preserves external ordinary-key access with delayed remote relocation. Managed mode optimizes namespace publication but requires our metadata reader or export. No silent conversion of an existing bucket.
9. **Detach is not discard.** Unmount can finish while the owner retains accepted work. Quit/update must explicitly respect pending work, active clients and durable restart intent.

## 4. Work packages

### ENG-01 — Ship a qualified native mount (release blocker)

**Owners:** `scripts/build-fskit-extension.py`, `scripts/fskit_packaging.py`, `NamespaceDriveController`, FSKit adapter. **Dependencies:** matching Apple profile/certificate and supported OS; no engine redesign needed.

- Build and embed the extension through existing profile validation. Capture app, owner, extension digests, profile entitlement checks, OS/build and mount mechanism.
- Verify OS activation and exact owned resource-to-mount mapping. Missing extension or activation must yield actionable unavailable state, never fallback labelled as native.
- Exercise Finder open, create, duplicate, rename, nested move, replacement, delete, reopen, eject and reconnect; run with remote service delayed/unavailable and with accepted dirty writes.
- Observe owner-originated upload visibility in an already-open Finder directory. If existing event propagation does not refresh it, add a revision-based invalidation bridge at the adapter boundary; resolve the actual SDK notification mechanism before implementation, rather than inventing an API.
- Retain a legacy path for existing compatible installations; switching must not start two writers or reinterpret a pending journal.

**Acceptance:** real mounted callback traces correlate operation UUID, local revision and user-visible completion. Accepted bytes survive owner kill/restart. Unrelated directories remain browsable during remote delay. Independent Finder eject is detected; a busy mount reports busy without deleting ownership records.

### ENG-02 — Dependency-aware scheduling and useful cancellation

**Owners:** `SyncEngine.processPending`, `OperationJournal`, `NamespaceOwner`; transport admission. **Dependencies:** ENG-01 can proceed independently; retain serial publication until concurrency tests pass.

Replace only the serial executor, not transaction admission. Introduce explicit execution categories: metadata publication, small upload, large upload, interactive download, pin/background download, relocation. Start with configurable bounded limits, not copied Helumi constants. Keep total request and memory budgets shared across categories.

- Compute readiness from durable dependencies and per-node generation/path reservations. Two disjoint uploads may proceed; ancestor relocation, replacement and successor generation operations must preserve order.
- Separate execution completion from contiguous published revision. Out-of-order success cannot advance the advertised published frontier beyond a gap.
- Managed HEAD publication remains a serialized conditional commit coordinator even if immutable content uploads run concurrently.
- Compatible copy/delete retains its inventory and verification barriers; no concurrent task may delete a source still needed by a retained reader or earlier accepted operation.
- Pause stops new scheduling; currently unsafe-to-interrupt commit stages complete or reconcile. Resume retries attention states only through error classification and proof checks.
- Cancellation semantics: cancel an unaccepted upload freely; cancelling accepted local writes requires an explicit recover/discard choice and must not masquerade as transfer pause. Do not expose a generic destructive cancel button merely because a Task is cancellable.

**Acceptance:** saturate large uploads and pins, then perform cached list/read/rename and a small upload. Record p95 and queue wait by lane. Fault-inject at every remote commit boundary with two overlapping operations. No newer generation is cleared, no duplicate accepted mutation, no premature revision frontier and no starvation in a ten-minute bounded-load run. Throughput improvement without these assertions is insufficient.

### ENG-03 — Bounded staging and large-namespace recovery

**Owners:** `ContentStore`, `NamespaceRecovery`, `ManagedManifestPublisher.exportRecords`, `RangeCache`. **Dependencies:** preserve on-disk compatibility or provide resumable migration.

Current `ContentSnapshot.extents` is a flat array (validated maximum 65,536 extents and 16 MiB snapshot read); startup reads all snapshot manifests into a dictionary. `restoreManaged` obtains all exported records before restoring. These are explicit scale review points, not evidence of an observed failure.

- Benchmark 100 GiB sequential and random-edit streams before choosing the redesign. Record metadata bytes rewritten per accepted MiB, extent count, startup time, peak RSS and fsync latency.
- If rewrite cost grows with history, use immutable extent-tree pages or an append journal plus compacted checkpoints. Bound each accepted write's metadata work. Stage and sync new pages before atomically referencing a root; never mutate pages referenced by older open generations.
- Page managed export/restore against one pinned HEAD with a durable continuation. Validate node uniqueness, parents, root, generations and content locators before exposing a complete tree. A changed remote HEAD requires restart/conflict handling, never mixing revisions.
- Make cache/index and locator-alias size limits observable. A full cache evicts only reproducible unpinned bytes; a full essential journal rejects further writes with recoverable local-storage guidance.
- Preserve old format readers during migration; create new records beside old records, switch only after validation, retain rollback evidence until accepted data is proven reachable.

**Acceptance:** large-file streaming and million-node recovery fixtures stay within a recorded budget independent of total file payload. Repeated random writes do not cause unbounded metadata amplification. Restart at every root/checkpoint boundary returns the last accepted state or a precise recoverable error. No full-dataset copy is required on the mutation path.

### ENG-04 — Large compatible operations and provider qualification

**Owners:** `S3StorageRemote`, `SyncEngine.processCompatible`, migration/export. **Dependencies:** live isolated-prefix authorization and provider capabilities; keep existing guards until evidence exists.

Source explicitly rejects compatible copy and final publication above 5 GiB. Multipart upload support does not prove multipart copy or atomic final ordinary-key replacement.

- Document each required request precondition: source validator, destination absence/match, final publication and source delete. Probe positive and deliberately failing conditions through the exact signed transport.
- Design multipart copy only if both source stability and final destination publication can be fenced. Persist upload ID, ordered part receipts, source identity, destination intent and completed-object verification before source deletion.
- If provider semantics cannot fence the final ordinary key, retain the block or present managed mode/export as an explicit alternative. Do not reduce safety to unblock a large move.
- Cover failed multipart completion, lost successful response, source replacement between parts, destination collision, throttling, expired credentials and restart after each receipt.
- Treat two independently running writers as conflict qualification, not a multi-writer collaboration feature. Establish a lease/merge protocol separately if collaboration becomes scope.

**Acceptance:** independently verified checksums for small and >5 GiB objects, no deletion before proof, external destination preserved during races, replays converge, and fixtures clean up only their generated prefix. Publish a capability matrix by transport/provider version.

### ENG-05 — Desktop file semantics and metadata

**Owners:** namespace schema/models, managed record format, compatible metadata policy, FSKit callbacks. **Dependencies:** representative application workflow captures, not assumptions that Helumi supports all POSIX features.

Run save/open fixtures for TextEdit, Preview and representative large/media/project files. Include atomic temporary-file replacement, package directories, Unicode normalization, case-only rename, names colliding after case folding, sparse/truncated files, Finder tags, resource forks, executable bits and symlinks. Record whether a capability is required, optional or rejected clearly.

For xattrs/tags/resource forks that are required, design bounded per-node metadata with generation/version checks and explicit synchronization/export preservation. Do not expose a capability flag before read/write/list/remove round trips work across cold recovery. For links, choose full stable-ID semantics or supported error behavior; a shortcut materializing link targets silently changes user data. Preserve the existing case-insensitive, case-preserving comparison contract unless migration explicitly handles collisions.

**Acceptance:** supported workflows save/reopen identically after rename, cold restart and remote reconstruction. Unsupported metadata produces a predictable error or documented loss warning before conversion/export, never silent corruption. Finder's UI reflects actual volume capabilities.

### ENG-06 — Recovery and operational diagnostics

**Owners:** owner lifecycle, sync receipts, recovery/export and status models. **Dependencies:** shared operation IDs across layers.

- Produce structured local diagnostics containing operation ID, node ID, generation, revision, phase and error category, with credentials and access-bearing URLs excluded.
- Recovery screen must distinguish: accepted local-only bytes, remote conflict, unknown outcome under reconciliation, unavailable original upload source, cache-only absence and invalid essential state.
- Offer retry, locate original source, export retained local data, inspect conflict and resume safe publication according to state. Never offer cache clearing as a repair for a corrupt essential journal.
- Test app crash, owner crash, extension crash, session logout, sleep/wake, disk full and filesystem power-loss simulation separately; SIGKILL tests do not prove power-loss durability.
- Keep retention/cleanup decisions inspectable with proofs. A diagnostic export must not copy raw credentials or unrelated user's objects.

**Acceptance:** every injected interruption has a deterministic restart result, retained data location and next action; no empty-drive presentation on corruption; recovered state is read-only until admission conditions are re-established.

## 5. Performance and experience gates

These are proposed BucketDrive targets inherited/refined from the earlier plan, not measurements of Helumi. Record machine, OS, storage, dataset, warm/cold conditions, sample count and percentiles.

| Scenario | Proposed acceptance |
|---|---|
| Local same-volume rename callback | p95 ≤100 ms, p99 ≤250 ms; zero remote request dependency |
| 100,000-descendant local folder move | Same callback budget; bounded changed rows; no descendant rewrite |
| Cached directory first page | p95 ≤100 ms with stable continuation; no network requirement |
| Cached metadata lookup | p95 ≤20 ms |
| Unrelated cached read/list while uploads saturated | ≤1 second in the defined qualification workload |
| Finder reflects accepted mutation | ≤1 second in otherwise idle Finder; separately report callback and UI delay |
| Eject with no busy handles | ≤3 seconds target; busy OS handles must remain an explicit error/state |
| File write accepted locally | No cloud RTT dependency; record size-specific p95, disk pressure and fsync cost |
| Crash after reply | Zero lost acknowledged namespace operations or required locally owned payloads |
| Keep downloaded | Offline success only after full required generation is present and validated |

No universal upload speed target is defensible without bandwidth, latency, request limits and payload mix. Report useful throughput and responsiveness together.

## 6. Verification plan and release sequence

Existing tests provide regression foundations: `NamespaceStoreTests.testRenameKeepsIdentityBackingAndDurableRequestAcrossRestart`, `testMutationAndJournalRollbackTogetherAtCommitFailure`, `testMoveOfHundredThousandDescendantsUpdatesBoundedRowsWithoutRewritingBacking`; `SyncEngineTests.testAcknowledgedWriteSurvivesReopenWithoutCloudPublication`, `testManagedLostHeadReplyAndMetadataMoveUseNoContentCopy`, `testVerifiedStagingGCSeparatesDirtyAndRetainedCleanHandleData`; `VolumeCallbackTests.testFolderRenamePreservesExistingChildIdentityAndNeverRequestsContent` and `testFailedCloseCannotReportOwnerDetachedAndCanBeRetried`.

For implementation changes, rebuild the standalone owner before lifecycle tests (`swift build --product CloudDriveEngine`), then run relevant Swift suites, packaging tests and the two explicit executable process-qualification modes described in [verification](../HELUMI_VERIFICATION.md). Record exact commands, source/artifact digests, logs and fixture identities; do not count a stale standalone owner as new source validation.

Sequence:

1. ENG-01 signed native qualification and ENG-04 real transport qualification, using existing implementation.
2. ENG-03 scale baselines and ENG-05 application-compatibility matrix; turn measured limits into bounded fixes.
3. ENG-02 scheduling improvements behind an internal flag, preserving serial fallback and data format.
4. ENG-06 fault/recovery matrix across the integrated candidate.
5. Limited opt-in native release after all critical integrity/mount gates pass; enable managed mode only with explicit preview/import/export path.

Each release report must distinguish **implemented**, **unit/fixture verified**, **signed mounted verified**, **live provider verified**, and **supported for release**. Any missing category remains an explicit gate. Exact functional and experiential parity with Helumi is not established by this specification; unresolved runtime comparisons stay on the investigation checklist.
