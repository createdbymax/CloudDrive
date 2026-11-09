# Helumi-style file management: implementation plan

Date: 2026-11-04  
Status: proposed implementation; this document does not implement or deploy the architecture.  
Scope: CloudDrive/BucketDrive Finder integration, namespace, storage, transfers, recovery, search, packaging and migration.

## 1. Intended outcome

Make the drive behave like a responsive local filesystem while cloud synchronization runs independently:

- Moving or renaming an existing file or folder completes after a small durable local transaction, without waiting for R2 copies, listings or deletion.
- Existing handles keep identifying the same file across moves. Finder can immediately browse the new location and open its contents.
- Finder writes are accepted into protected local staging, then uploaded in the background. The UI distinguishes saved locally from uploaded.
- Browsing uses local metadata. Opening remote content fetches the needed ranges, with bounded caching and a separate keep-downloaded policy.
- Eject detaches Finder promptly when the OS allows it. Accepted work remains recoverable and, while an owned worker is running, can continue in the background.
- Failed or uncertain remote operations become visible, recoverable states. They do not silently disappear, trigger destructive retries, or make the entire app appear crashed.
- Search, Finder, uploads and recovery agree about the same logical files and pending changes.

This is an original implementation of these behaviors. Helumi's proprietary code, server and storage format are not dependencies.

### Acceptance targets

These are proposed release gates, not measured performance claims. Record machine, storage, OS, dataset and percentile methodology in qualification results.

| Operation | Target under healthy local storage |
| --- | --- |
| Same-volume metadata-only rename/move | p95 <= 100 ms, p99 <= 250 ms for the filesystem callback after admission; no remote request on the acknowledgement path |
| Move a folder containing 100,000 descendants | Same acknowledgement budget; work proportional to ancestor depth rather than descendant count |
| Finder reflects a successful move | Visible within 1 second after notification in an otherwise idle Finder session |
| Cached metadata lookup | p95 <= 20 ms; no network dependency |
| First page of a cached directory listing | p95 <= 100 ms; bounded memory and stable continuation cookies |
| Unrelated cached read/list during a slow transfer | Completes within 1 second in qualification |
| Eject with no busy OS handles | Visible detach result within 3 seconds on healthy fixtures; actual unmount may fail or take longer when macOS holds files open |
| Cloud synchronization | Report measured progress and retry state; no fabricated universal completion-time guarantee |
| Crash after acknowledged mutation | Recover the accepted local operation and all required local payloads |

Finder may enumerate or inspect items before issuing a rename. Callback latency and the complete drag/drop experience must be measured separately. Cross-volume moves are copy/delete operations and cannot inherit the same metadata-only guarantee.

## 2. Evidence and boundaries

### Helumi findings from the installed artifact

Inspected `/Applications/Helumi.app`, version 0.3.13, build 39. The selected ARM64 filesystem executable is `Contents/Extensions/OrbitFS.appex/Contents/MacOS/OrbitFS`; its universal-file SHA-256 is `618174cb14b048fafe033e77baa022d2255c62ca631d7f6583ff81e10f542e98`.

| Finding | Evidence | Confidence and boundary |
| --- | --- | --- |
| FSKit filesystem extension | `EXExtensionPointIdentifier=com.apple.fskit.fsmodule`, FSKit linkage, implemented volume callbacks | Observed declarations and code; no runtime mount test |
| Separate Finder extension and mount helper | `OrbitFinder.appex`, FinderSync declaration, `OrbitMountHelper` executable | Observed bundle composition; complete process lifecycle not traced |
| Stable local nodes | `DriveNode.id`, `remoteID`, `parentID`, `name`, `contentVersion`, `metadataPending`; `DriveTree` operations | Observed symbols and selected machine code |
| Rename can update local namespace and queue metadata | `OrbitDrive.rename` at `0x1000836ac`; update closure at `0x100084bcc` writes name/parent and conditionally sets byte `0x70`; `metadataPending.getter` at `0x10004e068` reads that byte | Observed selected path; replacement and special cases exist, so this is not proof that every rename is network-free |
| Local write staging | `OrbitDrive.write` calls `Staging.write` then `DriveTree.update` | Observed call sites `0x10008098c` and `0x1000809f0` |
| Ranged reads and chunk cache | `ContentReader.read(offset:length:)`, `ChunkStore`, 1 MiB default chunk-size getter | Observed symbols/default; eviction correctness not tested |
| Distinct background scheduling | Upload lanes, metadata work, pending uploads, paused state, governor/pacer; defaults 6 small upload slots, 4 large slots, 8 metadata slots | Observed symbols/defaults; not recommendations to copy these numbers blindly |
| ID-based remote interface | `OrbitAPI.move(id:name:parentId:)`, separate content and metadata versions | Observed client interface; server's database, object keys and atomicity remain unknown |
| Local synchronization and unmount separation | Selected synchronize callback calls `DriveTree.save`; unmount callback directly invokes its reply; app contains `EjectWatcher` and upload messaging | Observed code; full eject/quit durability contract remains unverified |

REA evidence: plist `ev_593dfad60ba446c02522c811e827dd4077c7ee17cdee5f9905e52b2f8120fd61`; Mach-O inventory parent `ev_7e9ea4883e342b05bdc4a4c4a4b0bce7d9051a133d0ea09899b11e1d695a869d`. These are session evidence references, not repository artifacts. Deep decompiler providers were unavailable. The investigation used REA native inventory plus local symbol/disassembly tools, without launching Helumi, reading its account data or exercising its cloud service.

Do not infer that Helumi is crash-safe, has instant remote folder moves, or supports particular conflict semantics merely from these findings. The architecture below is our design.

### Current repository baseline

This is a working-tree inspection, including ongoing changes, rather than a clean released commit. Recheck the named interfaces before implementing; other work may advance them.

| Area | Current implementation | Consequence |
| --- | --- | --- |
| Finder mount | `Sources/CloudDrive/Drive.swift` starts patched rclone and mounts loopback NFSv3 using `mount_nfs` | Finder success remains coupled to NFS operation semantics |
| Folder moves | `FinderMoves.swift`, patches `0004-go-nfs-rename-handles.patch` and `0005-rclone-safe-moves.patch` | Journaled copy/verify/delete and handle repair improve safety, but remote work still precedes successful rename acknowledgement |
| Move concurrency | Current documentation describes retryable JUKEBOX results, affected-path guards and a short final namespace commit | macOS can hold parent vnodes while waiting; server responsiveness alone does not provide an instant move |
| Move limits | Documented 10,000 objects/directories and 32 MiB manifest | Large folders require a new namespace design, not simply higher bounds |
| Search catalog | `CatalogStore.swift`, `CatalogModels.swift`, `CatalogChanges.swift`, `CatalogController.swift` | Destination-bound SQLite/FTS projection; object identity is currently its key, not a stable filesystem identity |
| Finder writes/cache | rclone full VFS cache; `CloudCachePolicy.swift` currently requests 5 GiB target, 10 GiB free-space target and aggressive 1-second clean-cache eligibility | Existing protections must survive; clean range caching and pinned data need explicit ownership |
| Direct uploads | `DirectUploadEngine.swift`, `MultipartRemote.swift`, `UploadQueueStore.swift`, `UploadSourceReader.swift`, `UploadScheduling.swift` | Useful native multipart, source identity, durable receipts, request and memory admission foundations |
| Writer exclusion | Finder worker and native direct uploads are currently serialized by lifecycle gates | Concurrent UI workflows need one namespace owner before these gates can be relaxed |
| Eject | Working tree now contains fast detach plus `finishDetachedIfReady`/`finishDetachedWorker` in `Drive.swift` | Extend and qualify this work; do not reintroduce a fixed whole-operation upload-drain timeout |
| Ownership | `WorkerIdentity.swift`, authenticated `ControlClient`, generation/session checks, private records | Preserve process identity and fail-closed shutdown across the transition |
| Packaging | `Package.swift` targets macOS 14; generated Xcode project and `scripts/package-app.py` package app/helper/backend | FSKit requires an independently availability-gated extension, signing, embedding and release qualification |
| Remote model | Direct R2 bucket/prefix; no hosted CloudDrive account or metadata server | Preserve direct credentials and data access; design remote namespace publication explicitly |

The current `vendor/RCLONE_BUILD.json` reports `v1.75.2-clouddrive.5`; some behavior documents describe `.4`. Neither metadata nor rebuilt source proves which binary an already running worker uses. Qualification must record actual packaged and staged worker digests.

## 3. Architecture decisions

### A. A stable namespace is the foundation

Introduce a persistent filesystem namespace with stable node IDs and parent/name relationships. A logical rename changes one relationship and creates a durable synchronization operation. It does not rewrite every descendant path or touch remote content before returning success.

Keep paths derived from ancestry. Never use the full displayed path as the primary file identity. Do not make an eagerly rewritten full-path index a prerequisite for acknowledging a folder move.

### B. Use FSKit as the preferred adapter, after qualification

Build a thin FSKit extension over the shared namespace/IO engine. It owns callback translation and native item IDs, not a second independent tree or upload queue. Keep the existing NFS path available during rollout and for existing macOS 14 users.

Apple documents FSKit as an app-extension framework and lists its filesystem entitlement. FSKit became available in macOS 15.4; individual resource APIs have their own availability. For the first production path, target macOS 26+ and validate the path-resource approach against the installed SDK and a signed device build. Supporting 15.4 through 15.x is a separate compatibility milestone, not assumed from framework availability. [Apple FSKit](https://developer.apple.com/documentation/fskit/), [15.4 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-15_4-release-notes), [passthrough sample](https://developer.apple.com/documentation/fskit/building-a-passthrough-file-system), [path resources](https://developer.apple.com/documentation/fskit/fspathurlresource).

FSKit is not itself a cloud sync engine and does not make path-based R2 folder relocation atomic.

### C. Preserve existing bucket layouts; offer a managed namespace separately

Support two explicit storage modes. The current connection stays in compatible mode unless the user chooses a migration.

| | Compatible bucket mode | Managed drive mode |
| --- | --- | --- |
| Remote layout | Existing human-readable object keys | Reserved metadata objects plus immutable content objects identified independently of visible paths |
| Immediate move on this Mac | Persistent local overlay acknowledges first | Persistent local transaction acknowledges first |
| Remote folder move | Still bounded copy/verify/delete, potentially many requests | Publish changed namespace metadata; no descendant content copy |
| Other S3 tools | Eventually see final paths; may observe old/new prefixes during relocation | Need an export/view adapter to see ordinary file paths |
| Rebuild after local-state loss | Remote paths recover completed state; pending overlay may require protected recovery records | Remote manifest recovers published state; unuploaded local work still needs local staging/journal |
| Multiple writers | Initially unsupported; explicit conflict detection | Initially single writer, with conditional publication; collaborative merging deferred |

Recommended route: ship the local namespace and compatible overlay first, then make managed mode the preferred choice for newly created app-owned drives after its migration/export gates pass. Full Helumi-like fast *remote* moves require the identity-based mode or a metadata service. The installed Helumi client does not establish which exact service implementation to copy.

### D. Retain direct R2 operation

Implement the initial managed namespace using R2 objects and a conditionally published root pointer. A hosted Worker/D1 metadata service is an optional later alternative, not a prerequisite or silent change to the product's hosting/account model.

R2 documents atomic conditional `PutObject` evaluation, including `If-Match` and `If-None-Match`. Use these only where supported and test them through our exact S3 transport. Do not extend that guarantee to multipart completion or conditional deletion without separate evidence. [R2 conditional operations](https://developers.cloudflare.com/r2/api/s3/extensions/), [consistency model](https://developers.cloudflare.com/r2/reference/consistency/).

### E. One writer owns namespace and accepted data

One engine process owns mutable namespace, journal and staging per destination. App, Finder extension and upload UI are clients. Reuse process ownership concepts and an exclusive database owner lock. Use authenticated/versioned XPC or equivalent local IPC, with audit-token/code-identity checks and bounded messages.

Do not have the app and extension independently open write transactions against the same database. Do not let direct uploads publish keys behind the engine's back. An owner-lifetime spike must establish what remains running after Finder detach, window close, app quit, extension termination and logout. Until a separately managed background worker is signed and qualified, promise continuation only while the owning app/worker remains alive.

## 4. Components and integration points

Proposed names below are implementation destinations, not existing files.

| Component | Responsibility | Existing integration |
| --- | --- | --- |
| `CloudDriveCore` shared library target | Models, namespace transactions, journal, staging, remote interface | Extract reusable code from current executable target without importing UI |
| `NamespaceStore` | Stable nodes, directory lookup, versions, tombstones, atomic operation insertion | New authoritative store; do not repurpose the disposable catalog database |
| `OperationJournal` | Durable intent, dependencies, attempts, receipts, recovery transitions | Adapt move receipt principles and upload queue durability |
| `SyncEngine` | Admission, bounded metadata/content scheduling, retries, conflict handling | Integrate `DirectUploadEngine` transport/scheduling incrementally |
| `ContentStore` | Dirty staging and immutable local snapshots keyed by node/content generation | Preserve current direct-source identity handling |
| `RangeCache` / `ContentReader` | Validated ranged reads, caching, read coalescing and pinning | Native S3 signing/session patterns; keep independent from upload admission |
| `StorageRemote` | Content read/upload/copy, metadata publication, conditional root writes | `S3RequestSigner`, `MultipartRemote`, `ObjectInventoryRemote` |
| `NamespaceCoordinator` | One owner, operation leases, reader sessions, IPC | `WorkerIdentity`, lifecycle generation/session checks |
| `CloudDriveFS` extension | FSKit callbacks and native notifications | New Xcode extension target and adapter tests |
| `FinderAdapter` interface | Mount/detach/status/capabilities independent of implementation | Extract NFS-specific behavior from `Drive` |
| `FinderSync` extension | Badges and context actions: keep downloaded/free local space/retry | New optional target; filesystem correctness cannot depend on it |
| `CatalogProjector` | Revisioned filename/path search derived from namespace | Adapt `CatalogController`/`CatalogStore`; retain raw inventory indexing for compatible mode |
| `Drive` and presentation | Observable lifecycle/status and user actions | `Drive.swift`, `StatusPresentation`, Dashboard, Transfers, menu, Settings, Recovery |

Do not move all modules at once. Introduce testable interfaces, retain current adapters, and route one operation family at a time through the engine.

## 5. Persistent data and durability

### Namespace schema

Use private SQLite storage under a destination-bound directory; preserve owner/mode/no-follow/file-identity protections already used in `UploadQueueStore` and `CatalogStore`. Choose journal mode through measured crash and IPC ownership tests; keep `synchronous=FULL` initially rather than assuming WAL is required.

Minimum entities:

```text
volume(volume_id, destination_binding, mode, schema_version, local_revision,
       remote_root_etag, published_revision, owner_epoch)
node(node_id, parent_id, name_bytes, comparison_name, kind, logical_size,
     content_generation, metadata_generation, modified_at, deleted_revision)
content(node_id, generation, backing_kind, object_key, remote_validator,
        size, checksum_kind, checksum, staged_snapshot_id, publication_state)
operation(op_id, sequence, kind, node_id, base_generation, target_generation,
          expected_remote_revision, state, retry_after, attempt_count, error_code)
operation_dependency(op_id, depends_on)
remote_receipt(op_id, step_id, request_identity, observed_validator, outcome)
relocation(op_id, node_id, source_locator, target_locator, phase, cursor)
dirty_extent(node_id, generation, start, end, snapshot_id)
pin(node_id, recursive, requested_revision, state)
projection_outbox(sequence, node_id, revision, change_kind)
```

Use a durable volume ID distinct from credentials and UI labels. Key rotation must not orphan records. Reserve the root node. Add unique live `(parent_id, comparison_name)` constraints, parent existence/type checks and cycle detection. A local revision is monotonic and part of every publication/IPC notification.

Document filename semantics before exposing write support: byte-preserving S3 names versus macOS Unicode/case comparison, maximum names, unsafe keys, case-only rename and files whose names collide under local comparison. Quarantine unsupported imports for explicit export/rename instead of silently hiding or merging them.

### Acknowledgement rules

1. Metadata mutations succeed only after namespace change and journal/outbox insertion commit together durably.
2. Write acknowledgements require locally durable accepted bytes and recoverable extent metadata. Use a documented, tested ordering or a write-ahead extent record that survives failure between payload and SQLite persistence.
3. On macOS, qualify the actual filesystem flush primitive and power-loss boundary. `synchronous=FULL` on a database alone does not flush unrelated staged payloads.
4. Keep immutable snapshots for in-flight uploads. Subsequent writes increment a generation; an old upload completion cannot clear newer dirty data.
5. A successful local `fsync` means the documented local durability contract. It must not silently claim cloud replication. Offer a separate wait-for-cloud action when needed.
6. Persist remote receipts before retiring recoverable local state. A timeout is an uncertain outcome, not proof the operation failed remotely.
7. Publication, source reclamation and clean-cache eviction are separate transitions. Unknown state retains data.

## 6. Operation behavior

### Same-volume rename and folder move

Fast path:

1. Resolve source, destination parent and optional replacement by stable ID.
2. Validate permissions, name/case rules, replacement compatibility, root protection, ancestry and operation dependencies.
3. In one local transaction, change parent/name, create the operation with preconditions, and append the projection event.
4. Commit, update the in-memory revision and notify the filesystem adapter; return success.
5. Schedule remote metadata publication or compatible-mode relocation independently.

Readers retain node ID/content generation, not a path captured at open time. A folder move does not enumerate all descendants before step 4. Cycle checks traverse indexed parents and have a clear depth/corruption bound.

Support rapid sequences such as `A -> B -> C`, rename while a child uploads, delete after move, destination-name reuse and replacement of an open file. Coalesce only operations with equivalent preconditions and no externally published intermediate dependency. Preserve a durable history/idempotency boundary when coalescing.

After local acknowledgement, a remote failure keeps the new local name with a pending/error indicator. Do not automatically roll the namespace back underneath apps that have already opened the new path. Retry or present a specific conflict-resolution action.

### Compatible-mode relocation overlay

Keep logical parent/name independent of the current backing key. A moved file may continue reading its original key until its new content location is verified. A moved folder may use an ancestor relocation mapping; avoid writing a row for every descendant on the acknowledgement path.

Background work uses paged durable inventories and per-object receipts. Retain the existing copy-all/verify-before-delete safety barrier. Do not run two independent relocators over overlapping source/destination sets. Serialize destructive work for affected node subtrees and recheck generations at every publication boundary.

Required cases:

- Resolve reads through old backing locations during preparation and copy, then switch a verified locator atomically.
- Place new writes into new immutable generations while relocation owns old generations; never overwrite the sole source being copied.
- Route direct uploads and newly created descendants through the same overlay and dependency graph.
- Hide obsolete physical duplicates from the logical directory view and search.
- Preserve destination/source collision evidence and pause when remote state differs from preconditions.
- Reject unsafe destructive completion when external writers cannot be fenced. A HEAD followed by DELETE is not atomic protection against a concurrent writer. Maintain the single-writer contract; preserve ambiguous objects instead of deleting them.
- Persist the overlay before acknowledging Finder. Protect it as essential recovery state and clearly disclose that other S3 clients may still see original paths until sync completes.

The current journaled move implementation can supply remote executor ideas, but its long-lived VFS path model cannot simply receive an early success return. Route its namespace/handle lookups through the overlay first or keep this feature on the new adapter only.

### Managed-mode remote namespace

Proposed reserved prefix, after checking it is unused:

```text
<prefix>/.clouddrive/v1/HEAD
<prefix>/.clouddrive/v1/commits/<commit-id>
<prefix>/.clouddrive/v1/metadata/<immutable-page-id>
<prefix>/.clouddrive/v1/content/<content-id>
```

Use immutable namespace pages indexed by stable node ID and a parent/name index. A folder move rewrites the node and the two affected directory index paths plus commit metadata, not descendant content or every materialized path. Page fanout and commit size are bounded; a single monolithic whole-drive JSON file is not the design.

Publication protocol:

1. Upload new content generations and verify their receipts before a root can reference them.
2. Write immutable changed metadata/index pages and a commit object containing parent commit, operation IDs, generation and required hashes.
3. Conditionally replace the small `HEAD` pointer using the previously observed ETag; initialize with `If-None-Match: *`.
4. On a lost response, reconcile the root/commit ancestry and operation IDs before retrying. A negative lookup does not prove an in-flight write will never commit.
5. On precondition failure, fetch the new root and detect divergence. Initial release pauses conflicting publication; it does not implement silent last-writer-wins merging.
6. Only mark the operation cloud-published after the committed root includes it. Retain immutable objects for recovery/rollback until retention permits reclamation.

An ETag is an opaque publication precondition, not necessarily a content checksum. Initial mode is single writer per managed volume. A CAS root prevents blind overwrite but does not by itself provide collaboration, writer fencing or safe garbage collection.

### Create, write, replace and delete

- Create a local node immediately and link upload work to its stable ID.
- Stage write ranges without fetching an entire remote file just to accept a small edit; reconstruct missing ranges from the pinned base generation when publishing.
- Validate remote read ranges and object validators; never combine bytes from two content generations.
- Implement truncate, sparse gaps/zero fill, append and read-after-write with explicit extent rules.
- Handle temporary-file-plus-rename saves atomically in the local namespace, including open replacement targets.
- Retain unlinked but open content until the last handle closes and applicable journal dependencies finish.
- Use recoverable tombstones for new managed-mode deletion. Trash/restore needs a separate retention policy and UI; do not label a tombstone as a complete backup product.
- Existing compatible-mode delete semantics remain explicit until remote trash behavior is designed. Never silently change an existing user's remote retention policy.

### Direct uploads

Reuse multipart transport, source bookmarks/identity, memory admission, per-part receipts and completion reconciliation. Adapt the destination from a raw path lease to `(volume_id, node_id, generation)` ownership.

Direct uploads continue reading resident originals without an automatic full local payload spool. They may appear as clearly marked pending nodes in Finder, but reads before remote publication require the retained source to remain accessible. If that source disappears, report unavailable/pending rather than returning truncated data. Finder writes still require owned durable staging.

Permit simultaneous Finder browsing and direct uploads only after both use the same owner and operation ordering. Keep existing writer-exclusion gates for the legacy backend until that condition is proven.

## 7. Reads, local storage and offline behavior

- Cache keys include volume, content identity, generation and chunk/range coordinates. Moving a file never invalidates valid content solely because its path changed.
- Start with a benchmarked 1 MiB chunk candidate and configurable bounded prefetch; compare sequential media, random editing and small-file workloads before fixing defaults.
- Coalesce identical in-flight reads. Cancel unused prefetch independently of readers and uploads.
- Reserve IO/network admission for interactive reads and metadata. Saturated multipart uploads cannot consume every slot or memory allocation.
- Split storage accounting into dirty staging, clean cache, pinned content, metadata and recovery records. Show actual physical allocation separately from logical size.
- Evict only verified, reproducible clean content with no active reader/pin. Never trim dirty generations, unresolved receipts or sole local copies to meet a nominal cache size.
- Add disk high/low watermarks, per-volume quotas and reservations before accepting bytes. When no safe space remains, return a clear write failure without acknowledging data that was not saved.
- `Keep downloaded` is a durable pin request with progress, partial/failed state and recursive policy for future children. `Free local space` removes eligible clean cache, not originals or pending writes.
- Offline browsing uses known metadata; mark incomplete directories. Cached or staged ranges open offline, uncached ranges return a bounded offline error. Do not fabricate empty files/directories.
- Volume capacity reporting distinguishes remote quota from local writable staging headroom. Never advertise unlimited writable space when local acceptance cannot sustain it.

## 8. Lifecycle, eject and recovery

Represent independent dimensions rather than a single overloaded busy/error flag:

```text
Finder: detached | attaching | attached | detaching | blocked
Worker: stopped | starting | healthy | unresponsive | identityUnknown
Sync: idle | working | paused | offline | attention | statusUnknown
Durability: localPending | cloudPublished | verificationUnknown
```

Normal eject requests an ordinary unmount and stops admitting new filesystem operations once detach is underway. Do not force-unmount an uncertain volume. An OS busy error is reported as a detach failure with a useful action, not a transfer failure.

After confirmed detach, show `Finder ejected — finishing uploads` or `Finder ejected — finishing move` while the owned worker continues. Do not label healthy background work as a broken connection. Shut the worker down automatically only after a fresh authenticated idle/safe-to-stop check, no active readers/writers, and revalidation of session/generation and mount state.

Existing `finishDetachedIfReady`/`finishDetachedWorker` work is the starting point. Preserve its authentication and uncertain-status behavior. Do not treat a missing move sample, dead queue UI or stale idle value as permission to terminate.

Window close retains ownership. Normal app quit can pause at a durable boundary and exit only after mount/worker policy allows it. Until a background service is implemented, explain that quitting pauses synchronization. An update must negotiate quiescence with the same owner before replacing binaries. Force Quit/logout/power loss are recovery scenarios.

Recovery procedure:

1. Validate destination, schema, store identity and owner identity before adopting anything.
2. Replay committed journal entries; repair incomplete local transactions only from validated extents/records.
3. Reconcile unknown remote publications and multipart operations using durable operation IDs and receipts.
4. Restore the latest accepted local namespace before mounting it; mark work still pending remotely.
5. Detect changed/unavailable direct-upload sources and remote precondition failures explicitly.
6. Retain read-only diagnostics and recovery export when integrity cannot be established. Never initialize a new empty store over pending state.

Local journal loss before cloud publication can lose pending metadata or staged content. Add recovery export/backup and explain this boundary. Managed remote manifests recover published state, not bytes that never left this Mac.

## 9. Finder adapter, UI and search

### FSKit adapter

Implement and qualify lookup, attributes, paged enumeration, create, rename, remove, open/close, range read/write, truncate and synchronization. Translate errors accurately and invoke every reply exactly once. Run database/network work off the main actor and outside global namespace locks.

Use stable native item IDs derived from volume/node identities, with generation protection against ID reuse. Enumeration cookies need a documented revision model when directories mutate. Supply native invalidations after namespace changes and remote reconciliation. Test name normalization, case-only rename, resource forks/xattrs, `.DS_Store`, symlinks and ordinary atomic-save patterns. Advertise unsupported hard links, locking or other capabilities honestly.

Do not enable new write support until signed extension activation, entitlement provisioning, extension restart and engine reconnect have passed. Apple's [FSVolume documentation](https://developer.apple.com/documentation/fskit/fsvolume) and [filesystem entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.fskit.fsmodule) are implementation references; use the actual installed SDK signatures.

### Presentation

Show short user states: `Saved on this Mac`, `Uploading`, `Up to date`, `Waiting for internet`, `Paused`, `Needs attention`, `Finder ejected — finishing changes`. Distinguish namespace publication from payload transfer without exposing journal implementation details in the normal flow.

Transfers should include moves and metadata changes alongside uploads, with per-operation state, retry and affected-item navigation. Progress uses real discovered/processed counts; never manufacture a percentage before total work is known. Cancellation after an acknowledged move means stopping future sync at a safe boundary; undo is a new durable inverse operation, subject to current state.

### Search

Keep `CatalogStore` rebuildable. Feed it a durable namespace outbox; acknowledge events only after projection commits. Search results use stable node IDs and resolve current paths when opened. Old keys/path projections cannot become the authority for IO.

Folder moves invalidate ancestry-derived paths lazily or through revisioned background updates. Results must resolve against current ancestry even while full-path FTS projection catches up. Managed mode excludes internal content/manifest objects. Compatible mode overlays pending logical paths on remote inventory and suppresses obsolete duplicates. Preserve existing scan-gap reconciliation for external raw-bucket changes.

## 10. Migration and compatibility

### Existing app users

1. Detect unresolved legacy moves, dirty rclone cache, direct-upload jobs and active workers. Complete/recover or retain them with the old backend; do not reinterpret their records as new-engine operations.
2. Safely detach and confirm exclusive ownership before creating a new namespace store for that destination.
3. Inventory metadata without hydrating file contents. Import stable nodes and backing locators in resumable page transactions.
4. Mount the new adapter read-only for verification, compare counts and representative paths, then enable writes through a feature flag.
5. Keep the legacy implementation available for fully synchronized compatible-mode rollback. If a pending overlay exists, rollback must first finish/export it; the legacy worker cannot see those accepted logical changes.

### Optional managed-mode adoption

Offer a preview with object count, metadata-space estimate, possible server-side copy cost, storage-format change and interoperability/export implications. This plan authorizes no live bucket conversion.

Prefer a new dedicated prefix. For existing keys, allow content locators to reference unchanged original objects initially; they become managed dependencies and must be protected from outside mutation. Copy to immutable content keys in resumable background work when required. No source deletion occurs merely because metadata import succeeded.

Persist migration ID, original inventory validators, checkpoints, new root and verified receipts. Publish a complete validated root before advertising the drive as adopted. Keep originals until an explicit retention/cleanup decision and safe verification. A mixed or interrupted migration is resumable; it is never mistaken for an empty drive.

Provide an export tool that materializes ordinary directory-shaped keys into a separate prefix and verifies them. Never promise an instant in-place downgrade of managed storage. Preserve remote manifests and local journals across app downgrade; incompatible schema means read-only/recovery, not destructive recreation.

## 11. Delivery phases and concrete work packages

Dependencies are intentional. Assign independent scopes to implementers only after shared interfaces and invariants are agreed; integrate and qualify centrally.

| Phase | Work and ownership boundary | Completion gate |
| --- | --- | --- |
| P0: baseline and contracts | Record actual staged backend/build; finish existing eject qualification; capture slow-move/write traces and crash evidence; define name/durability contracts | Reproducible fixtures, measured baseline, no unresolved ambiguity about active worker |
| P1: shared core and stores | Extract `CloudDriveCore`; add namespace/journal/staging interfaces, migrations, exclusive ownership, recovery and fault injection | Crash-safe local rename/write/replace tests; existing app/tests still build |
| P2: compatible sync engine | Add ID/locator overlay, dependency graph, paged relocation executor, multipart adapter and unified status | Instant local transactions under delayed R2; read-after-move and all injected recovery cases pass |
| P3: FSKit vertical slice | New signed extension, mount adapter, IPC/owner lifecycle; read-only first, then write/rename | Signed real Finder move/edit/eject with slow network and restart qualification |
| P4: integrate workflows | Route direct uploads through owner, project namespace into search, add statuses/pins/badges and storage accounting | Concurrent Finder/direct upload/search consistency; no removed legacy protections |
| P5: managed namespace | Immutable metadata pages/content, conditional root publication, conflict stop, recovery, import/export | Live isolated R2 conditional-write/lost-response tests; move uses no content copy |
| P6: migration and rollout | Feature flags, compatibility matrix, migration preview/checkpoints, signed packaging, updater quiescence | Restart/rollback/export and upgrade from prior signed app pass |
| P7: sustained qualification | Large trees, media workloads, long outages, disk pressure, worker death and power-loss simulation | Published evidence matrix meets acceptance targets; remaining limits visible |

Suggested implementation order within P1–P3:

1. Define `VolumeID`, `NodeID`, `ContentGeneration`, `NamespaceRevision` and versioned IPC messages.
2. Implement transactional create/lookup/rename/remove against synthetic locators.
3. Prove durable local acknowledgement and recovery before adding network work.
4. Add range reads and staged writes with generation isolation.
5. Add remote scheduling and compatible relocation recovery.
6. Implement a minimal signed FSKit mount using the same engine.
7. Wire production UI and search only after the native vertical slice meets its contract.

Candidate file-level changes:

- `Package.swift`: add shared core/test targets; keep UI and platform adapter boundaries explicit.
- `scripts/generate-xcode-project.py`: produce shared targets plus FSKit/Finder extension dependencies and embedding; preserve generated-project reproducibility.
- `scripts/package-app.py`, signing/release tooling: nested extension entitlements/profiles, correct inside-out signing, backend/version inventory and notarized package checks.
- `Drive.swift`: delegate mount/worker actions to adapter/coordinator; retain generation/session guards and safe detach.
- `FinderMoves.swift`: adapt legacy progress/records into unified operations without silently adopting old journals.
- `DirectUploadEngine.swift`/`UploadQueueStore.swift`: add an adapter to engine-owned node/generation jobs; retain transport receipts and legacy recovery.
- `CatalogModels.swift`/`CatalogChanges.swift`/`CatalogController.swift`: stable logical IDs and transactional projection outbox.
- `CloudCachePolicy.swift`/`LocalStorage.swift`: separate legacy VFS policy from new cache/staging/pin accounting.
- Dashboard/menu/Transfers/Recovery: render independent mount/sync/durability states and bounded next actions.
- New proposed directories: `Sources/CloudDriveCore/`, `Sources/CloudDriveFS/`, `Sources/CloudDriveFinder/`, corresponding core/adapter test targets and synthetic qualification fixtures.

## 12. Verification matrix

All new tests must establish behavior or safety properties; avoid tests that merely mirror helpers. Preserve existing tests and fixture qualification while both backends are supported.

| Category | Required scenarios and proof |
| --- | --- |
| Namespace | File/folder/case-only rename, deep folder move, cycles, root protection, Unicode collisions, replacement and repeated operations; stable IDs and no descendant traversal before ack |
| Handles | Open file/directory handles before move; continue read/write afterward; open replacement and unlink; no stale-path identity substitution |
| Local durability | Crash at every payload/extent/journal/transaction boundary; acknowledged bytes and namespace survive; unacknowledged partial work is safely classified |
| Generations | Write while upload/copy runs; old receipt cannot clear new dirty state; partial edits and truncation preserve untouched base bytes |
| Remote outcomes | Delayed request, lost successful response, 401/403/404/412/429/5xx, malformed body and interrupted multipart completion; reconcile without blind overwrite/delete |
| Large workloads | 0/2/10,000/100,000 descendants; paged inventories and bounded memory; no pre-ack per-object HEAD; metadata commit request count measured |
| Managed publication | Missing-page rejection, CAS conflict, unknown root write, ancestry verification, incompatible manifest and recovery from published root |
| Compatible overlay | A->B->C, nested moves, destination reuse, new child during move, concurrent source edit, copy barrier failure and external mutation detection |
| Reads | HTTP ranges, truncated/invalid range response, changing ETag, offline partial cache, sequential media, random reads, read priority under upload saturation |
| Storage | Low disk before and during acceptance, sparse allocation, pins, cache trimming, removable source disappearance, metadata store unavailable/corrupt |
| Lifecycle | Eject during preparation/copy/upload, busy unmount, stale idle/unknown status, remount race, app/extension/worker death, quit/update and restart |
| Finder | Actual drag/drop of files and folders, batch move, Get Info, previews, editing with atomic save, copy into/out of volume and cancellation |
| Search | New logical path immediately resolves while FTS catches up; pending duplicates suppressed; outbox replay and interrupted projection converge |
| Migration | Existing pending jobs block unsafe adoption; interrupted import, reserved-prefix collision, read-only verification, export and downgrade gates |

Qualification levels must be reported separately:

1. Pure local/store and synthetic remote fault tests.
2. Native mounted adapter with synthetic service, including actual Finder operations.
3. Developer ID signed package with extension activation/restart, IPC identity, updater and installed-worker digest checks.
4. Isolated real R2 prefix with independent readback/checksum and conditional-write tests.
5. User-approved representative large workload. Do not use the user's Photos folder as an automatic test fixture.

Run relevant existing `swift test` suites and legacy `scripts/qualify-finder-moves.py`, `scripts/qualify-finder-copy.py`, `scripts/qualify-preservation.py` and allocation checks when their code paths change. New proposed harnesses should reuse synthetic S3 fixtures and add deterministic lost-response/CAS/disk-failure controls. Test results must identify which backend and package they exercised.

## 13. Diagnostics and rollout

Record operation ID, node ID, local/published revision, generation, phase, request latency, retry reason, queue age, callback latency, cache category bytes and active adapter/worker build identity. Keep credentials, control tokens, signed URLs and private file contents out of exported diagnostics; redact paths by default. Preserve an explicitly requested private recovery export separately.

Add local feature flags for namespace engine, FSKit adapter, managed storage and unified direct-upload ownership. Storage mode and pending-operation state are persisted capabilities, not flags that may be toggled off underneath accepted work. A kill switch can stop new admissions or mount read-only while preserving replay/export.

Roll out synthetic -> signed development -> isolated real R2 -> opt-in compatible mode -> managed new drives -> broader default. Do not delete the old backend until compatibility, recovery and export obligations are resolved.

### Release checklist

- [ ] All accepted metadata and bytes satisfy the declared durability contract.
- [ ] Folder move acknowledgement has no cloud request or descendant enumeration dependency.
- [ ] New paths open immediately; stable handles survive moves.
- [ ] Compatible remote relocation and managed publication have independent qualification evidence.
- [ ] Unknown outcomes preserve records and sole data copies.
- [ ] Eject, quit, update and restart use one owner and consistent state.
- [ ] FSKit target activation/signing and OS availability are verified on shipped artifacts.
- [ ] Legacy jobs/caches remain recoverable; no automatic storage-format conversion.
- [ ] Search and transfer UI reflect logical namespace and local/cloud durability accurately.
- [ ] Live R2 tests use dedicated prefixes with independently checked content.
- [ ] Migration/export/rollback instructions and actual measured limitations are published.

## 14. Decisions to close during implementation spikes

Default proposals make the plan actionable; change them only with documented evidence and corresponding tests.

| Decision | Proposed default | Evidence needed before release |
| --- | --- | --- |
| Initial native OS support | FSKit macOS 26+, retain legacy macOS 14 path | Signed path-resource/extension lifecycle matrix |
| Owner process | Dedicated engine owner retained by the app; one mutable store owner | Demonstrated lifetime/IPC behavior after detach and extension restart |
| Background continuation after app quit | Pause durably; no promise of continuation | A separately signed/qualified background service before changing this contract |
| Existing connection storage mode | Compatible; no automatic conversion | Pending overlay recovery and export tests |
| New app-owned managed drive | Offer after P5/P6 qualification | Format specification, CAS tests, import/export and user-visible choice |
| External writers | Unsupported initially; detect and pause conflicts | Proven fencing/merge design before broader support |
| Initial cache chunk | Benchmark 1 MiB candidate | Random/sequential workload and amplification measurements |
| Cloud metadata service | Direct R2 immutable metadata + conditional HEAD | Exact transport and lost-response qualification |
| Remote cleanup | Retention-based explicit maintenance; no initial aggressive GC | Reachability, active-reader, pending-publication and rollback safety proof |
| Initial conflict resolution | Preserve both states and request a specific resolution | Deterministic divergent-generation tests |

The first meaningful milestone is a signed Finder drive that moves a large folder immediately, opens files from its new path, survives a worker restart, and finishes its remote work without blocking unrelated operations. A faster copy loop or FSKit mount alone does not meet that milestone.
