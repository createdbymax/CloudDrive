# Qualification and delivery plan

Date: 2026-11-05. Scope: development planning only. No new test run, mount, cloud write, migration, release or qualification is claimed by this document.

The deliverable is an app whose observable workflows match the Helumi reference closely, while preserving BucketDrive's direct-storage model. “Exact same functions and feelings” is an acceptance objective, not a result established by static inspection. Each claimed match needs a reference scenario, a BucketDrive scenario, and retained evidence. Internal architectural similarity alone cannot satisfy that objective.

## 1. Current evidence and remaining proof

The working tree already contains substantial namespace implementation. Do not restart the project from the older November 4 plan or interpret an untracked file as an absent feature. The prior verification report and actual source/test files are the baseline; they are not proof that today's changed source is the exact tested artifact.

| Area | Current evidence | What remains |
|---|---|---|
| Core namespace, app and adapter tests | `../HELUMI_VERIFICATION.md` reports 397 tests: 285 app, six adapter, 106 core. Inspected `../../build/helumi-all-final-tests.log` includes the 106-core zero-failure summary and `NAMESPACE_100000_RENAME elapsed=0.003470167 ... sqlite_changed_rows=18`. | Reproduce against a frozen candidate after implementation changes. One measured rename is not a latency distribution or Finder result. |
| Process-level recovery | `../../scripts/qualify-namespace-engine.py::main` starts an explicit owner executable against generated local JSON-backed storage and performs five grouped checks. | Real mounted callbacks, provider behavior, process/signature enforcement and power-loss guarantees. |
| FSKit | `../../Sources/CloudDriveFS/CloudDriveFSVolume.swift`, adapter tests and reported unsigned Xcode extension build. | Signed, provisioned activation and real Finder scenarios. SwiftPM adapter compilation excludes `CloudDriveFSExtension.swift`; it does not prove the shipping extension works. |
| Candidate packaging | Prior report describes a signed inactive app with no filesystem extension. `../../scripts/package-app.py::package` writes `BuildInfo.json`; `check_inactive` rejects rebuilding a running output. | Repackage with a valid FSKit profile and verify the exact installed app/owner/extension. |
| Provider transport | `../../Tests/CloudDriveCoreTests/S3StorageRemoteTests.swift` independently tests signing, ranges, preconditions, multipart reconciliation and >5 GiB preflight rejection. | Isolated live R2 behavior for conditions, unknown outcomes and external writers. Loopback success is not R2 qualification. |
| User experience | Presentation and routing tests exist; see §5. | Side-by-side visible workflow captures, latency distributions, accessibility, scrolling and failure-state review. Rendering a view is not evidence of interaction fidelity. |
| Large workloads | Bounded core tests and one 100,000-descendant move; prior report explicitly leaves sustained workloads open. | 100 GiB writes, staging growth, long outages, disk pressure and prolonged mixed traffic. |

Historical log paths are local artifacts and may not be committed. Copy selected results and their SHA-256 identities into the final release evidence bundle rather than relying indefinitely on these paths. This document inspected existing evidence; it did not rerun the reported suites.

## 2. Fixture and evidence contract

Create a deterministic fixture generator as a development task. It must output a manifest containing logical path, stable fixture ID, byte size, SHA-256, timestamps and generation seed. Include:

- Empty files/directories; names containing spaces, emoji, composed/decomposed Unicode and mixed case; deep ancestry and large sibling sets. Encode expected case/normalization behavior explicitly instead of assuming every filesystem agrees.
- Small objects of 1 B, 4 KiB and 1 MiB; objects straddling cache chunk and multipart boundaries; a >5 GiB object; a sustained 100 GiB generated stream. Generate large content incrementally.
- A 100,000-descendant tree, a wide 10,000-entry directory, and an unrelated readable folder.
- Replacement pairs with distinct content hashes; a file opened before rename/unlink; an externally modified remote object; intentionally corrupt local metadata and downloaded ranges.
- A cloud fixture manifest under a newly generated, isolated qualification prefix. Cleanup may remove only manifest-owned objects after post-test evidence capture. Existing user data is never a fixture.

Record one `run.json` per candidate/scenario group, with:

```json
{
  "schema": 1,
  "candidate": {"commit": "...", "dirtySourceManifestSHA256": "...", "buildInfoSHA256": "..."},
  "binaries": {"appSHA256": "...", "ownerSHA256": "...", "extensionSHA256": "..."},
  "host": {"osBuild": "...", "architecture": "...", "memoryBytes": 0, "storageKind": "..."},
  "reference": {"appVersion": "...", "artifactSHA256": "...", "scenarioEvidence": "..."},
  "fixture": {"manifestSHA256": "...", "mode": "compatible|managed", "cache": "cold|warm"},
  "scenario": "Q-FS-01",
  "result": "pass|fail|blocked|unobserved",
  "measurements": {},
  "evidence": [],
  "limitations": []
}
```

Store monotonic durations separately from wall-clock timestamps. Redact credentials, IPC tokens, signed URLs and account details. Keep object names synthetic. A failed run stays in the ledger; reruns append results and explain the change.

## 3. Instrumentation work required before benchmarking

Add correlated spans at these boundaries without putting telemetry on correctness-critical synchronous paths:

1. UI action accepted → command dispatched → owner request admitted.
2. Filesystem callback received → namespace transaction committed → reply delivered.
3. Notification emitted → Finder visibly reflects change (external observation).
4. Staging bytes accepted → durable local acknowledgment → upload admitted → remote verification → namespace publication receipt.
5. Remote request started/finished; retry reason; request class; bytes sent/received; unresolved outcome.
6. Eject requested → handles closed → volume detached → detached-worker state settled.
7. Search query changed → result computation complete → first visible results.

Use a run-local correlation ID plus node ID and generation, not a raw path or credential. Report queue depth, oldest pending age, active metadata/read/upload slots, peak resident memory, staging/protected/clean/pinned bytes, open handles and SQLite changed-row counts. Add bounded diagnostic export from the existing authenticated owner channel rather than an unauthenticated listener.

The inspected namespace/FSKit source did not establish a complete signpost-based performance harness. Treat this instrumentation as work to implement. `qualify-namespace-engine.py` currently measures only one rename duration with `time.monotonic()` and asserts <250 ms; retain that smoke test but do not label it p95/p99.

## 4. Functional acceptance scenarios

Run each applicable scenario in compatible and managed mode. For OS-facing cases run the exact provisioned extension; for lifecycle cases run both owner-originated operations and actual Finder interactions. Mark legacy NFS separately and never pool its results with FSKit.

| ID | Steps / fault | Required observable result | Existing foundation |
|---|---|---|---|
| Q-FS-01 | Open a child handle; delay remote responses; rename its 100,000-descendant parent; enumerate new path and read old handle. | Same node/inode and bytes; immediate local success; cloud work separate; unrelated listing stays responsive. | `NamespaceStoreTests.testMoveOfHundredThousandDescendantsUpdatesBoundedRowsWithoutRewritingBacking`, `VolumeCallbackTests.testFolderRenamePreservesExistingChildIdentityAndNeverRequestsContent`. |
| Q-FS-02 | Rename A→B→C; create child; move a child out; crash between accepted operations. | Recovery preserves accepted order and paths, no duplicate visible tombstones or lost children. | `SyncEngineTests.testRapidFolderMovesNewChildAndMovedOutChildPreserveAcceptedOrder`. |
| Q-FS-03 | Replace a file while its old handle is open; unlink and write via retained handle. | Old handle identifies its own generation; new path identifies replacement; deleted names never resurrect. | `testReplacementRetainsOldOpenHandleAndNewNodeIdentity`, `testOpenUnlinkedWriteIsDurableLocalOnlyAndDoesNotResurrectPath`. |
| Q-FS-04 | Read a directory in pages, mutate it, reuse stale or wrong-directory continuation. | Explicit restart/error policy; no cross-directory result leakage or silently wrong entry. | `DirectoryCursorTests.testContinuationCannotBeReusedForAnotherDirectoryOrRevision`. |
| Q-IO-01 | Cold read then random seeks, simultaneous identical ranges, truncated/wrong-content-range/changed-validator response. | Correct bytes or explicit failure; no cache poisoning; duplicate reads coalesce within bounded admission. | `testRangeValidationCoalescingAndPinsKeepCacheBounded`, `S3StorageRemoteTests.testStrictRangesRedirectAndPrefixEscapeAreRejected`. |
| Q-IO-02 | Partial overwrite, shrink, regrow, zero-length write, crash/reopen at each accepted boundary. | No discarded-byte resurrection; replay cannot overwrite a newer generation. | `testPartialWriteAndTruncateNeverResurrectDiscardedBytes`, `testTruncateReplayDoesNotTruncateANewerWrite`. |
| Q-IO-03 | Pin contents, fill clean cache, free space, then disconnect network. | Pinned/dirty/open-generation bytes retained; only eligible clean bytes evicted; offline data availability accurately shown. | `SyncEngineTests` storage/pinning/GC tests; add mounted and UI coverage. |
| Q-SYNC-01 | Drop reply after successful PUT, copy, DELETE, multipart completion or HEAD publication. | Durable uncertain state reconciles without overwrite, duplicate destructive work or false success. | `S3StorageRemoteTests` lost-response cases; `SyncEngineTests.testManagedLostHeadReplyAndMetadataMoveUseNoContentCopy`. |
| Q-SYNC-02 | Mutate source/destination remotely before conditional operation; provider ignores DELETE precondition. | Conflict stops unsafe work and preserves evidence; invalid provider cannot become qualified. | `testProviderIgnoringDeletePreconditionCannotBecomeQualified`, `testChangedSourceNeverAdmitsDeletion`. |
| Q-SYNC-03 | Attempt ordinary-key relocation of >5 GiB object. | Current implementation rejects before mutation with useful explanation. Do not claim large compatible move parity until a safe multipart-copy protocol is implemented and tested. | `testLargeCompatibleCopiesAndMetadataChangesFailBeforeMutation`. |
| Q-SYNC-04 | Pause, restart, resume while metadata and payload work exist. | Pause persists; safe local operations stay responsive; resumed work continues from verified receipts. | `NamespaceOwnerTests` and owner lifecycle coverage. |
| Q-LIFE-01 | Finder eject while uploads run; inspect app status; reopen volume; quit/update attempt. | Detach state and background work distinct; no worker killed solely because window closes; accepted data protected. Busy-volume refusal is truthful. | `NamespaceLifecycleTests.testNativeFinderEjectReconcilesMountAndRetiresIdleOwner`, `VolumeCallbackTests.testUnmountClosesRetainedHandlesBeforeDetachingOwner`. |
| Q-LIFE-02 | Lost control response, stale successful response, foreign mount/resource, corrupt capability, symlinked state. | Fail closed; no foreign process killed, stale state resurrected or state silently recreated. | `NamespaceLifecycleTests` and `NamespaceOwnerTests`. |
| Q-REC-01 | Import metadata, interrupt after committed page before checkpoint; resume. | Idempotent import, no phantom empty file or payload download just for metadata enumeration. | `NamespaceMigrationTests.testMetadataImportReplaysPageCommittedBeforeCheckpointWithoutDownloadingPayloads`. |
| Q-REC-02 | Recover managed namespace into new empty local state; interrupt; resume; export to fresh ordinary-key prefix. | Stable identities and bytes; original state retained; incomplete view hidden; export never deletes source or overwrites occupied target. | `NamespaceMigrationTests` restore and export cases. |
| Q-APP-01 | Upload via app while namespace selected, then search/rename/pin through app and Finder. | One authoritative logical tree; no legacy queue fallback or raw relocation duplicates. | `NamespaceRoutingTests.testDirectUploadHandoffDoesNotCreateLegacyJobsOrModifyOriginal`, `testAuthoritativeNamespaceResultsHidePhysicalRelocationDuplicatesAndTombstones`. |
| Q-APP-02 | Select read-only recovered/preview mode; try upload, drag/drop and mount/write commands. | Consistent disabled or actionable error state; no hidden legacy mutation. | `NamespaceRoutingTests.testSelectedReadOnlyManagedModeBlocksLegacyWriterAndUploadFallbackEvenWhenStopped`. |

## 5. “Feel” and visual acceptance

Use the experience specification in `03-EXPERIENCE-SPEC.md` to define the intended screen states. For each reference capture, record window size, display scale, appearance, locale, keyboard focus, data state and reduced-motion setting. A string in a binary proves text exists, not that a control appears on a particular screen. Unavailable authenticated Helumi flows remain unobserved until exercised.

Capture paired scenarios for: launch/onboarding; connect/setup failure; idle mounted drive; uploading; paused; retrying; offline; completed; queued work after eject; low storage; search empty/loading/results; preferences; quit/update with pending work. Evaluate:

- Information hierarchy and primary action placement; density at minimum and normal window sizes.
- Consistent selection, keyboard navigation, focus rings, Escape/dismiss and standard shortcut behavior.
- No layout jump when speed/remaining-time text changes or long names appear; progress must not reset on harmless refresh.
- Pointer-to-feedback latency, animation duration/easing and interruption behavior. Exact Helumi timing remains a measurement task, not an inferred constant.
- Light/dark, increased contrast, Reduce Motion, VoiceOver names/roles/value announcements and full keyboard operation.
- Truthful local/cloud distinction through every transition. `NamespacePresentationTests.testLocalSaveCannotBeShownAsCloudCompletionUntilPublicationCatchesUp` is a semantic foundation; add interaction captures.
- UI remains usable during import, cache work and many transfers. Count main-thread stalls and dropped frames during repeatable scroll/resize/search sequences.

Use screenshot diffs for stable geometry with deliberate masks for timestamps, progress and system chrome. Review animation recordings separately; a screenshot cannot prove smoothness. Where original BucketDrive branding differs intentionally, document the allowed difference. No universal pixel-difference percentage substitutes for review of meaningful controls.

## 6. Proposed performance gates

These are BucketDrive targets carried forward or added for qualification, not measured Helumi performance. If paired measurements show a perceptual gap, revise the target deliberately and record why.

| Measurement | Initial gate | Method |
|---|---|---|
| Local same-volume rename callback | p95 ≤100 ms, p99 ≤250 ms | At least 1,000 operations across repeated warm runs; separately test 100,000-descendant parents. Instrument callback and transaction separately. |
| Cached lookup / first listing page | p95 ≤20 ms / ≤100 ms | Warm local metadata, no remote requests on critical path; report directory size. |
| Finder-visible rename | ≤1 s in idle fixture | Time from user action to observed new row; report Finder preflight separately. |
| Unrelated cached work under transfer | ≤1 s | Concurrent reads/listings during constrained large transfers; inspect tail latency. |
| Eject with no busy handles | ≤3 s | Actual Finder unmount; record busy-handle refusal separately rather than forcing it into success statistics. |
| Interactive search feedback | Initial proposed p95 ≤100 ms for cached first results | Fixed query sequence, catalog sizes and cancellation; do not conflate indexing time with query time. |
| Visual action feedback | Initial proposed ≤100 ms | Capture input and first visible state change; long work may continue asynchronously. |
| 100 GiB sustained writes | Correct bytes, bounded resource growth; publish measured throughput | Hour-scale mixed IO, record RSS, disk writes, staging growth and extent metadata rewrite cost. Set numeric memory/throughput budget only after baseline. |

Warm/cold runs, disk types, OS builds and mode are separate populations. Publish count, p50/p95/p99/max and failures. Report failures rather than excluding slow operations. Use monotonic timing, a stable power state and representative storage. Test at least one supported older macOS fallback configuration and every FSKit OS version actually claimed for release.

## 7. Failure injection and long-run matrix

Inject faults at named protocol/transaction boundaries, not arbitrary sleeps alone:

- Before/after namespace commit; before durable local reply; before/after remote receipt persistence; before/after publication HEAD update.
- Owner SIGKILL, extension termination, app termination, machine restart. Distinguish orderly restart, process death and actual power loss; passing one does not imply the others.
- ENOSPC, write/fsync error, truncated staging manifest, valid-JSON integrity corruption, SQLite busy/IO error, state-directory replacement.
- Network offline/online, high latency, bandwidth cap, 429/5xx, expired multipart session and remote object changed during read/copy.
- Saturate data IPC slots while issuing metadata/status/eject operations; verify reserved capacity without unbounded queues.
- Pause/unpause repeatedly, sleep/wake, long outage with accepted local work, and cache pressure while old handles remain open.

Run deterministic unit faults first, process tests second, signed mounted tests third, then overnight mixed workloads. Snapshot synthetic fixture state before destructive injection so failures are reproducible. Require byte-level verification after recovery; a successful status code is insufficient.

## 8. Development sequence and exit criteria

| Phase | Concrete work | Dependency | Exit artifact |
|---|---|---|---|
| D0 — Evidence baseline | Freeze source manifest; capture installed Helumi identity; map observable workflows; classify unknowns; preserve current tests/logs. | None | Capability matrix with observed/inferred/proposed labels and paired scenario IDs. |
| D1 — Measurement foundation | Add correlated owner/adapter/UI timing; deterministic fixture generator; structured run manifest; bounded diagnostic export. | D0 | Reproducible local baseline; no secrets in diagnostics. |
| D2 — Native activation | Obtain matching Apple profile through normal developer provisioning; package extension; activate on test Mac; qualify mount ownership and Finder callbacks. | Existing FSKit code, valid profile | Signed exact-artifact Q-FS/Q-LIFE evidence. No substitute ad-hoc activation claim. |
| D3 — Data guarantees | Live isolated R2 conditional operations, unknown-outcome reconciliation, cold ranges and managed recovery/export; fix observed discrepancies. | D1; scoped disposable cloud fixture | Q-SYNC/Q-REC pass, retained receipts and final hashes. |
| D4 — Interaction parity | Implement experience-spec gaps, truthful status/transfer states, Finder refresh and optional FinderSync capability, accessibility and motion refinements. | D0, D2 for Finder integration | Paired captures and keyboard/VoiceOver review; explicit intentional differences. |
| D5 — Scale and compatibility | Profile extent rewrite costs; bound resource growth; stress scheduling; implement safe large compatible copy only if required; qualify claimed OS matrix. | D1–D4 | Sustained workload report and zero unexplained integrity failures. |
| D6 — Release candidate | Repeat suites after changes; test packaged owner and extension; updater/quit/cache preservation; clean install and upgrade from retained legacy state. | All applicable gates | Versioned release evidence bundle, known limitations and rollback/recovery procedure. |

Phases can overlap only when dependencies are met; for example UI fixtures can progress while provisioning is pending. Native mounting remains unavailable until D2 passes. Compatible >5 GiB moves remain blocked until their own protocol is safe; managed large upload success does not remove that gate.

## 9. Reproducible local checks

Run from the repository root after implementation, saving complete logs and tool versions. These commands are a runbook; they were not executed in this documentation task.

```sh
swift build --product CloudDriveEngine
swift test
python3 -m unittest discover -s Tests/Signing
python3 scripts/qualify-namespace-engine.py --engine .build/debug/CloudDriveEngine
python3 scripts/qualify-namespace-engine.py --engine .build/debug/CloudDriveEngine --managed
python3 scripts/build-fskit-extension.py --configuration Release --output build/fskit-parity
```

Build the standalone owner first: app lifecycle tests can otherwise pick up a stale executable. Repeat both generated process checks against the exact packaged `Contents/Resources/CloudDriveEngine` and compare the reported digest with `BuildInfo.json`. Generated fixture mode bypasses production peer enforcement by design and must never count as signed-peer qualification.

Packaging is controlled by `CLOUDDRIVE_INCLUDE_FSKIT=1`, `CLOUDDRIVE_FSKIT_PROFILE`, and optionally `CLOUDDRIVE_FSKIT_EXTENSION`; use `scripts/fskit_packaging.py::requested_profile` and `embed_extension`. The validator requires the explicit `local.bucketdrive.app.filesystem` identity, FSKit entitlement, unexpired profile, matching certificate and team. Preserve these gates. `codesign --verify --deep --strict` is necessary signature evidence but does not establish activation, notarization or successful callbacks.

## 10. Final acceptance and reporting

A parity claim is ready only when every required row in the capability matrix has source evidence, a testable behavior contract and passing candidate evidence. Publish counts by observed match, intentional difference, unresolved reference behavior, implementation gap and qualification blocker. Never roll all five into a single “complete” percentage.

Release blockers currently documented are FSKit provisioning/activation, actual Finder workflows, live R2 semantics, sustained workload/memory/disk qualification, and large compatible-copy support if that capability is promised. Optional FinderSync badges/context menus are an implementation gap, not a failed core adapter test. Authentication/account/subscription flows that belong to Helumi's hosted service require a separate product decision; direct R2 operation cannot silently be described as identical hosted-service functionality.

The documentation package may be complete while behavioral parity remains incomplete. The final engineering handoff should state both clearly.

## Implementation follow-up (November 5)

The original assessment above remains a baseline. The subsequent authorized implementation adds:

- `scripts/qualify-namespace-engine.py --rename-samples N --output-json NEW_PATH`: bounded repeated rename samples, count-aware nearest-rank percentiles, successful per-operation IPC round trips, host and fixture identities, and private new-only evidence output. These measurements remain a three-object synthetic process fixture, not Finder latency or a large-tree benchmark.
- `scripts/check-fskit-readiness.py APP`: read-only resource-contract, artifact digest, signature, profile and entitlement prerequisite checks. It never activates or installs an extension.
- FSKit `OwnerRPC` signposts for profiling without payload/path logging, and stricter packaging checks for the secured path-resource module declaration.
- An optional sandboxed FinderSync action extension and strict `FinderActionRequest` parser. See `../FINDER_ACTIONS.md`; badges and mounted interaction qualification remain separate.
- Ordinary-key uploads above 5 GiB now fail before reading source bytes or creating multipart state, matching the existing compatible-copy limitation. Managed immutable multipart uploads are unaffected.

Safe large compatible multipart publication is still unresolved. Cloudflare's current [S3 compatibility table](https://developers.cloudflare.com/r2/api/s3/api/) explicitly lacks conditional source headers for UploadPartCopy; its CompleteMultipartUpload row does not establish destination compare-and-swap. Do not bypass the existing preconditions or treat a HEAD-before-write sequence as atomic publication.
