# Direct uploads from external drives

Research and implementation plan · November 3, 2026

Status: historical planning record. The subsequent implementation includes durable multipart resume in the first version, using a native Swift transport instead of the initially proposed transient rclone jobs. See [implemented behavior and qualification scope](DIRECT_UPLOADS.md). No real-provider operation or release has been performed.

## Recommended outcome

Add a native **Upload directly** drop zone to CloudDrive. Dropping files or folders from Finder queues references to the originals, then reads their contents from the external drive into bounded memory buffers and sends them to R2. There is no intermediate copy into the mounted CloudDrive folder, internal SSD, or temporary payload directory.

Use the supplied screenshot as the visual reference: a rounded, quiet card with an upload icon, a strong summary, byte count and ETA, one progress bar, a divider, and filename rows with percentages or states. Extend it with a destination, source-drive status, and accessible actions.

**Storage promise:** upload files much larger than the Mac's available storage, without local payload staging. Queue metadata still needs writable storage. Support a full internal disk by allowing the small job journal on a writable external volume. Do not promise successful operation of macOS itself at literally zero writable space.

Sources remain unchanged. Completing an upload must never delete the external original. A folder drop is a one-time upload, not a watched folder or synchronization relationship.

## What the repository does today

Inspected clean worktree at `5170189`; macOS 14+ SwiftUI app, bundled backend `v1.75.2-clouddrive.1`.

| Current source | Relevant behavior | Consequence |
| --- | --- | --- |
| `Sources/CloudDrive/Drive.swift` | Starts `rclone serve nfs`, with full VFS caching, two transfers, and authenticated loopback control. | Finder writes stage whole files locally. Sending drops to this mount would retain the storage problem. |
| `Sources/CloudDrive/CloudCachePolicy.swift` and `docs/LIMITATIONS.md` | Clean data can be reclaimed; dirty/open data must remain. | Reducing cache limits cannot make a large pending upload fit. |
| `Sources/CloudDrive/UploadProgress.swift`, `UploadProgressView.swift`, `TransfersView.swift` | Presents the outstanding VFS queue; avoids claiming disappeared rows are verified completions. | Reuse formatting and visual patterns, but direct uploads need their own durable jobs and completion receipts. |
| `Sources/CloudDrive/WorkerIdentity.swift`, `Runtime.swift` | Validates worker ownership; bounds commands and control requests. | Reuse these principles; do not force upload-only workers into NFS-specific recovery records. |
| `Sources/CloudDrive/App.swift`, `UpdateController.swift` | Quit and updates are gated by drive state. | Both gates must also account for upload-only jobs. |
| `Sources/CloudDrive/Connection.swift`, `DriveState.swift` | Keychain credentials and sanitized worker environment. | Reuse without persisting credentials in the new queue. |
| `experiments/streaming-nfs/README.md` | Separate synthetic prototype with special chunks, explicit publication, restricted operations. | It is a different project; direct reads of existing source files do not need a streaming filesystem rewrite. |

The bundled executable's version and upload-related flags were inspected. The bundled source archive was also read: multipart copying reads sequentially into part buffers, initializes an upload per invocation, and normally attempts abort on error. No end-to-end direct upload was run during research.

## Research findings and architecture choice

### Prefer the existing backend for the first implementation

Cloudflare documents direct directory uploads with rclone. Implement an app-owned queue using a dedicated authenticated `rclone rcd` worker and asynchronous `operations/copyfile` jobs, one source file per app job. The destination is the configured R2 prefix directly, never the NFS mount. Validate these operations against the pinned binary in the first implementation milestone. [Cloudflare upload guide](https://developers.cloudflare.com/r2/objects/upload-objects/), [rclone control API](https://rclone.org/rc/).

This retains the existing backend, signing, and credential integration. A native Swift S3 client is possible, but would introduce a second transport, signing, retry, and multipart implementation. Use a dedicated uploader implementation only when durable part-level resume is required.

R2 supports multipart uploads with 5 MiB–5 GiB parts, at most 10,000 parts, and equal sizes except the last. Its default lifecycle aborts incomplete uploads after seven days; bucket configuration may differ. Multipart ETags are not a whole-file MD5. [R2 multipart details](https://developers.cloudflare.com/r2/objects/upload-objects/).

Rclone buffers multipart chunks in RAM, can increase chunk size for very large files, and may count buffered bytes before remote completion. Treat byte progress as provisional. [rclone S3 backend](https://rclone.org/s3/).

### Explicitly separate retry from resume

The first release can retry transient requests while a job is alive and restart an interrupted file from the original. Completed files remain complete. It must not claim to resume a partially uploaded file after process death. Stock app-level rclone job tracking does not provide a persistent upload-ID/part ledger.

If a 500 GB video is interrupted near completion, restarting that file can be expensive. Make durable multipart resume the next reliability milestone, with a separate engine behind the same queue interface. Do not market “resumable uploads” before that milestone passes fault tests.

### Do not run two uncoordinated writers

The NFS mount can have open handles, dirty cache, and queued writes. A direct upload can conflict with these even if a remote listing looks clear. A cloud existence check alone does not solve that race.

For the first release, use exclusive destination modes: **Finder drive** or **Direct upload**. When a drop arrives with Finder connected, retain the references and offer one explicit **Finish Finder uploads and switch** action. Use the existing safe eject/drain path; blocked recovery or unconfirmed worker exit blocks the switch. Keep the mount disconnected during direct writes. Offer reconnect after the batch finishes. Do not unexpectedly eject a volume as a side effect of a drop.

This is a deliberate v1 interaction cost. Later simultaneous use requires enforced destination leases in the mounted backend covering create/write/rename/delete and pending dirty data, plus cache invalidation; a Swift-only lock cannot constrain native Finder writes. Multi-Mac concurrent writers remain outside current support.

## Proposed user flow and card

1. The dashboard shows **Drop files or folders to upload directly**, with **Choose Files…** as a keyboard-accessible alternative. The picker accepts multiple files and folders. Connection credentials are required; a mounted drive is not.
2. Show the destination breadcrumb before a drop. Initially upload to the configured prefix; an optional explicitly selected subfolder must remain within it. Never infer the destination from whichever Finder window is frontmost.
3. Resolve real source URLs, validate access, persist accepted references, and enumerate off the main actor. Show **Preparing upload…** while totals are incomplete. Clean, nonconflicting batches start automatically once prepared and the destination mode is available.
4. Replace the drop zone with the reference-style card. Example: **Uploading 3 files…**, **540 MB of 2.05 GB · About 4 min left**, a progress bar, and the three filename rows. Keep a small **Add files** target available during a batch.
5. Use states **Waiting**, **Checking file**, **Uploading 62%**, **Finishing**, **Checking upload**, **Uploaded**, **Retrying**, **Drive disconnected**, and **Needs attention**. A successful request and verification, not a missing stats row, creates **Uploaded**.
6. Secondary text identifies the source volume and says **Keep this drive connected until uploads finish**. Show **Pause after current file**, **Cancel**, and per-file **Retry** in the expanded Transfers view. Do not label cancellation-and-restart as true pause/resume.
7. Show a persistent batch result: uploaded, skipped, and failed counts, with retry for failures. Destination reconnect is separate from upload success.

Visual implementation: SwiftUI rounded card, system background/material where legible, black circular upload glyph, semantic secondary text, restrained progress track, monospaced metrics. Aim for roughly 460 pt width with flexible sizing; support dark mode, increased contrast, VoiceOver, reduced motion, long filenames and keyboard navigation. Use system file-type glyphs rather than reading video thumbnails, which could trigger unnecessary I/O or hydration.

For a folder, preserve the dropped root: `Wedding/Clips/a.mov` becomes `<prefix>/Wedding/Clips/a.mov`. Multiple dropped files keep their basenames. Document this behavior beside the destination. Folder progress aggregates descendants; file counts must refer to leaf files consistently.

## Components and integration

```text
Finder file URLs / NSOpenPanel
           |
           v
SourceResolver -> off-main enumerator -> durable UploadQueueStore
                                              |
                                    UploadCoordinator actor
                                      /              \
                           DestinationGate       DirectUploadWorker
                           (Finder vs direct)    (owned rclone rcd)
                                                       |
                                          external file -> RAM -> R2
                                              |
                                     verification + receipt
                                              |
                                    UploadQueueViewModel
                                              |
                                  dashboard / Transfers / menu
```

| Proposed file | Responsibility |
| --- | --- |
| `DirectUploadModels.swift` | Versioned batch/file/attempt IDs, source identity, destination binding, states, receipts. |
| `UploadSourceResolver.swift` | Real URLs, source volume/file identity, bookmarks where applicable, bounded enumeration. |
| `UploadQueueStore.swift` | Transactional journal, recovery, quotas and chosen state volume. |
| `UploadCoordinator.swift` | Serialized transitions, scheduling, retries, cancellation, aggregate metrics. |
| `DirectUploadWorker.swift` | Own upload-only worker lifecycle and typed copy/status/stop/stat calls. |
| `DestinationWriteGate.swift` | Prevent overlapping NFS and direct writers for one destination. |
| `DirectUploadCard.swift`, `UploadDropTarget.swift` | Reference-style presentation and native file URL drop receiver. |

Extend `Runtime.swift` with strictly decoded async job responses and session-scoped identifiers. Generalize reusable process ownership utilities without changing the NFS record schema accidentally. Update `App.swift`, `Drive.swift`, `DashboardView.swift`, `TransfersView.swift`, `DriveMenu.swift`, `UpdateController.swift`, and storage reporting. New source files must be included by the Xcode generation workflow as well as SwiftPM.

### Queue records and recovery rules

Persist a batch ID; job/attempt ID; endpoint/bucket/prefix fingerprint; destination key; root-relative source path; source volume identifier; file resource identifier where available; size and modification metadata; access bookmark where supported; state; retry count; worker session/job mapping; and verified receipt. Credentials never belong in the journal. Bookmarks and paths are private metadata.

Use SQLite with transactions and a bounded WAL/checkpoint policy, or an equivalently bounded journal; choose one in milestone 1. Do not rewrite an entire growing JSON manifest after each progress sample. Durable state transitions matter; transient speed samples need not be fsynced.

Persist intent before launching a copy. A timed-out control request may have started a job: reconcile its unique attempt/stats group with the owned worker before retrying. If ownership is uncertain, block another writer rather than launching a duplicate. On restart, verified receipts remain complete; reconcile running/unknown jobs with the exact worker, remote identity and source identity.

### Source access and folder policy

- Use native file URL pasteboard objects via an AppKit drop bridge, or an equivalent proven in-place SwiftUI route. Never read complete `Data`, receive a copied temporary representation, or stage a file promise as the normal drop path. Apple distinguishes file references from file contents and file promises. [Apple drag-and-drop guidance](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/DragandDrop/Tasks/DraggingFiles.html).
- Retain access for the full queued lifetime. Use bookmarks/security scope where required and balance access calls. Verify that the actual signed child worker can read authorized files; parent access must not be assumed to transfer automatically. A future sandboxed build may need a different file-descriptor transport.
- Enumerate incrementally with bounded memory, descriptor count, and cancellation. Set explicit depth, entry and metadata quotas; report partial enumeration as incomplete. Deduplicate overlapping drops. Skip the app's own journal directory.
- Reject sources inside the CloudDrive mount and its payload cache. Avoid feedback loops and hydration.
- Do not follow symlinks or aliases outside the selected tree. For v1, report skipped links and unsupported special files explicitly. Treat hard-linked regular files as separate named objects. Do not cross nested mount points implicitly.
- Handle Unicode, spaces, newline characters and case distinctions as names, never shell syntax. Validate encoded keys, destination containment and collisions. Never normalize two distinct source names into one key silently.
- Exclude macOS volume service folders such as `.Trashes`, `.Spotlight-V100`, and `.fseventsd`; preserve other ordinary hidden files unless explicitly skipped. Explain that resource forks, Finder metadata, ACLs, sparse allocation, and package semantics are not preserved as a Mac backup format. Do not descend into packages automatically without a clear supported policy.
- Empty directory preservation needs a supported marker convention and mount round-trip proof. Report it unsupported until tested; never claim byte-for-byte filesystem preservation.
- Before each attempt validate volume identity, file identity, size and modification metadata. Recheck after transfer, retaining rclone's source-update detection. A different disk remounted at the same `/Volumes/name` must not be accepted as the original. FAT/exFAT identities and coarse timestamps need explicit qualification; ambiguous identity requires re-selection.
- Restrict the initial promise to resident local/external files. Cloud placeholder providers can download into internal storage when opened; identify/reject unsupported placeholders rather than claiming that all Finder sources are storage-free.

### Memory and disk budget

Initial tuning proposal for qualification: one file at a time, two concurrent multipart parts, 16 MiB nominal parts, 4 MiB read-ahead, bounded buffer pool, and no multi-thread transfer path until qualified. Start with `--transfers 1`, `--s3-upload-concurrency 2`, `--s3-chunk-size 16Mi`, `--buffer-size 4Mi`, `--max-buffer-memory 96Mi`, and `--multi-thread-streams 0`. Keep the configured bandwidth limit. Select a multipart threshold explicitly during benchmarking.

These are proposed settings, not measured guarantees. Calculate the effective part size from known file size before admission; reduce concurrency for larger required parts. The buffer limit is not a total-RSS limit, and macOS may swap under memory pressure. Target backend RSS below 256 MiB for the representative <=100 GiB workload, then measure and publish limits for larger files. Never turn a RAM buffer into a disk-spooled payload to meet the target.

Only queue data, recovery records and bounded diagnostics may be written locally. Set an initial journal budget, for example 64 MiB, with page-based admission and bounded history; benchmark supported file counts before freezing that budget. No queue may grow without limit.

For low-space operation:

1. Probe the chosen metadata volume with an actual allocation/write/fsync test; do not compare free space to total payload size.
2. Default to private Application Support when writable. If it cannot admit a job, offer **Store upload records on this external drive** or another writable selected volume. Explain the small sidecar; do not write onto a source disk silently.
3. The external metadata mode must cover the DB, WAL, control secrets, lock, worker launch/session records and bounded diagnostics. Audit executable staging too: `WorkerExecutable.stage` currently makes private digest-addressed copies. Reuse a verified existing copy, or support verified staging on the selected state volume. A hidden internal staging write must not defeat full-disk mode.
4. A remembered external state location helps rediscovery. If the internal disk cannot persist that pointer, provide **Recover Upload Records…** so the user can select the external journal after restart. Bind it to the current user, destination and source identities; never trust imported process records without validation.
5. If the metadata volume disappears or a durable transition cannot be recorded, stop admitting work, preserve uncertainty and reconcile on recovery. Do not mark success on an unrecorded outcome.
6. A read-only source is supported when another metadata volume is writable. With no writable metadata location, explain the requirement and decline to start a durable batch. Never silently switch to an unrecoverable RAM-only queue.

Strict zero-internal-write execution remains a qualification target, not a general OS guarantee: app launch, security services, OS logs and swap can still need disk. Describe tested conditions accurately.

### Verification and destination collisions

Default to **Keep both**, with a deterministic persisted suffix for conflicting names. Provide explicit **Skip** and **Replace** choices for existing objects; never use `sync` or `move`. Reserve in-app keys across all batches. Recheck before launch; the single-writer mode protects against the app's Finder worker, not arbitrary external clients.

For the first version, require the existing one-active-writer deployment contract and state that remote preflight is not an atomic no-clobber guarantee against outside writers. If concurrent remote clients become supported, qualify conditional publication for both single PUT and multipart completion. R2 documents atomic conditional PUT behavior; do not extrapolate that to every multipart operation or backend flag. [R2 S3 compatibility](https://developers.cloudflare.com/r2/api/s3/api/).

After a successful copy result, verify remote identity and size through the S3 backend and compare an available trustworthy checksum. Preserve default integrity checks; if hashing a huge source is slow, show **Checking file**. Size alone establishes only a size check. For synthetic qualification, download and compare a full cryptographic digest. Do not automatically download user payloads into the local cache for verification. Display **Checking upload** until the supported verification contract finishes, and retain its strength in the receipt.

An ambiguous completion response goes to **Checking upload**, not immediate failure/re-upload. Reconcile the object with this attempt's source/checksum evidence. A matching filename and size alone must not attribute an unrelated pre-existing object to the attempt. Verified remote upload plus failed Finder reconnect remains an uploaded file with a separate connection issue.

### Interruptions, cancellation and lifecycle

| Event | Planned behavior |
| --- | --- |
| Network interruption | Bounded exponential retry with jitter; keep references; distinguish retryable failures from credentials/permission failures. |
| External drive unplugged | Pause affected jobs, show the volume name, wait for the same identity or explicit re-selection. No internal copy fallback. |
| Source edited/deleted | Mark needs attention; do not certify a changed source or substitute a new file silently. |
| Sleep / wake | Recover requests and revalidate volumes on wake. Optional user-controlled prevention of idle sleep while active; no promise of transfer during sleep. |
| Pause | Stop scheduling after the current file. Explain this boundary in the action label. |
| Cancel active file | Request stop, await confirmed terminal job state, reconcile possible completion; attempt multipart cleanup. Keep originals. A published object is not automatically deleted. |
| App restart | Recover durable queue; completed files stay complete; unresolved v1 files restart only after reconciliation. |
| Window close | Background uploads continue while app is running. |
| Quit / update | Block installation or offer an orderly stop-and-save flow covering both worker types. Do not leave an untracked uploader. |
| Connection changed | Old jobs stay bound to their destination fingerprint. Changing Settings never redirects a queued job. |

Incomplete multipart cleanup must be confined to known owned jobs; do not run bucket-wide cleanup on the user's prefix. Without a persistent upload-ID ledger, hard-killed v1 transfers may leave parts for the existing lifecycle rule. Explain that limitation and inspect lifecycle expectations in provider qualification; never edit bucket lifecycle automatically.

## Implementation sequence and exit criteria

| Milestone | Work | Required evidence |
| --- | --- | --- |
| 1. Transport feasibility | Use the pinned rclone binary against a disposable local S3 fixture; direct source reads, authenticated async jobs, stats grouping, cancellation, size/hash checks. Establish effective RAM behavior and journal design. | A generated file larger than a constrained state volume uploads correctly without payload writes there. Establish actual source-change and cancel behavior. |
| 2. Queue and recovery | Durable job store, destination gate, private worker identity, source validation, retries and ambiguous-outcome handling. | Crash before/after dispatch and remote completion cannot lose a completed receipt silently or create concurrent attempts. |
| 3. Drag/drop and screenshot UI | Native URL drop target, mixed files/folders, picker, card, expanded rows, durable batch totals and receipts. | Real Finder drop from an external volume; nested paths preserved; responsive preparation; VoiceOver and keyboard checks. |
| 4. Full-disk support | External metadata location, launch staging audit, quotas, rediscovery, state-volume removal handling. | Full internal-volume simulation succeeds with external state; no internal payload; full state volume stops safely. |
| 5. Integration and qualification | Quit/update/eject rules, bandwidth setting, reconnect, docs, pinned backend fault tests. | Existing tests pass; synthetic workload/failure matrix below passes. Separately authorize and qualify real R2 with disposable generated data. |
| 6. Durable part resume | Dedicated Go uploader using S3 multipart primitives behind the same interface, if needed. Persist upload ID, fixed part size, part numbers/ETags/checksums and source identity; reconcile ListParts and commit receipts. | Restart near the end of a large upload sends only missing parts; changed sources are rejected; expired uploads restart explicitly; cancel/recovery cleanup is scoped. |

Rough planning allowance: 2–4 engineering weeks for milestones 1–5 including fault qualification; 1–2 additional weeks for durable multipart resume. These are estimates, not commitments; revise after milestone 1, especially for sandbox access, volume identity and external-state behavior.

## Acceptance matrix

- **Large file / tiny free space:** generated 50–100 GiB source on a separate volume, state volume with roughly 100–256 MiB free; verify remote digest and measure all allocated local bytes. Source size must exceed writable state capacity substantially. Sparse fixtures alone do not establish real read throughput.
- **Internal disk full:** isolated quota-limited/sacrificial environment, never fill the user's startup disk. Exercise a pre-existing worker and cold launch, external state, executable staging, record recovery and Keychain access. Distinguish constrained-volume evidence from full-system evidence.
- **No payload staging:** monitor Application Support, state folder, caches and temporary directories throughout the transfer. Compare allocated bytes, not logical size. Exercise files above the multipart boundary and several object sizes.
- **Folders:** deep nested directories, 100,000 small entries within the declared quota, Unicode, spaces, newlines, case collisions, overlapping drops, hidden files, empty directories and packages. Reports must account for every skipped or unsupported entry.
- **Volumes:** APFS and exFAT; read-only source; unplug/replug; a different drive with the same name; source/state on the same disappearing volume; state quota exhaustion.
- **Faults:** lost dispatch response, lost completion response, repeated HTTP errors, authentication failure, source mutation, cancellation during finalization, worker death, app death, sleep/wake and restart after remote completion before receipt persistence.
- **Writer safety:** connected Finder with dirty files, open handles, failed eject, blocked recovery, repeated drops during mode switch, multiple batches targeting the same key. No unsafe worker adoption or second writer.
- **Presentation:** stable totals once preparation completes, no double counting on retry, stale stats hidden, unknown ETA shown honestly, 100% buffered bytes does not prematurely display Uploaded, persistent partial-failure result, 50+ rows without UI stalls.
- **Regression:** existing Swift tests and local Finder/cache/recovery qualification remain valid. Update `README.md`, `docs/ARCHITECTURE.md`, and `docs/LIMITATIONS.md` to distinguish direct upload from staged Finder copying.

The first implementation should begin with milestone 1, then lock the user-visible storage and interruption contract before polishing the card. The feature is complete only when direct source uploads and low-space recovery have been demonstrated, not when the drop target alone works.
