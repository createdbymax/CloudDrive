# Personal Mac drive implementation — 2026-11-05

Scope follows the user's implementation request and clarification: **no sharing or public file requests; this is a personal Mac cloud drive**. Existing uncommitted work was preserved. The following changes extend the current namespace implementation rather than replace it.

## Implemented

| Area | Changes | Owning sources |
|---|---|---|
| Everyday interface | Compact default drive-status window; full management remains available; native primary actions and accessible status | `Sources/CloudDrive/CompactDriveView.swift`, `App.swift`, `DriveMenu.swift` |
| Truthful state | Shared published predicate validates counters, dirty bytes, revisions and active work; stale samples never claim confirmed cloud data; offline pin progress and attention remain distinct | `StatusPresentation.swift`, `NamespaceTransfersView.swift`, `NamespaceDriveController.swift` |
| Activity | Bounded durable per-file operation feed, unfinished first and recent completed history, stable operation IDs; no fabricated byte percentages | `Sources/CloudDriveCore/NamespaceActivity.swift`, `NamespaceOwner.swift`, `NamespaceTransfersView.swift` |
| Search | Configurable Option–Space / Control–Option–O / disabled shortcut; stable node identity and selection through rename/reorder/deletion/async refresh | `CatalogModels.swift`, `SpotlightPanelController.swift`, `SpotlightSearchModel.swift`, `DriveSettingsView.swift` |
| Setup | Resumable prerequisite checklist; mode-aware copy and ownership routing prevent legacy upload fallback for read-only/encrypted namespaces | `NamespaceManagementView.swift`, `ConnectionViews.swift`, `Drive.swift` |
| Retained deletion | Explicit Move to Recently Deleted action, hidden ordinary-node recovery layout, collision-safe restore, original parent fallback to root, atomic local journal and replay-safe requests | `NamespaceTrash.swift`, `NamespaceTrashView.swift`, `NamespaceFileActions.swift` |
| Finder actions | Optional sandboxed FinderSync extension for bounded multiple-selection keep/free-space actions and activity; strict URL parsing, explicit confirmation and live owned-mount validation | `Sources/CloudDriveFinder/`, `FinderActionRequest.swift`, `App.swift`, `NamespaceDriveController.swift` |
| Managed uploads | Up to three immutable-content preparations concurrently, bounded/configurable 1–4; durable dependency order and serialized managed HEAD publication remain authoritative | `SyncEngine.swift` |
| Upload rate | Shared configurable native upload budget, durable rate selection and applied-rate readback; encrypted requests charge ciphertext bytes; part-sized wire bursts remain possible | `UploadBandwidth.swift`, `NamespaceOwner.swift`, `docs/NATIVE_UPLOAD_RATE.md` |
| Offline indicators | Search and activity show current-generation checksum-verified cached availability, with a 5-second freshness limit; bounded verification returns unknown when proof is unavailable | `RangeCache.swift`, `AvailabilityBadge.swift` |
| Compatibility recovery | Returning to an earlier path with the same content validator no longer creates relocation alias cycles; durable aliases are compacted; semantic receipt comparison tolerates older JSON key ordering | `ContentStore.swift`, `SyncEngine.swift` |
| Scale admission | Extent splitting respects the existing extent limit; managed recovery has a decoded-memory budget; unsupported >5 GiB compatible uploads reject before source reads/network | `ContentStore.swift`, `ManagedManifest.swift`, `NamespaceRecovery.swift`, `S3StorageRemote.swift` |
| Encryption | Opt-in new managed drives encrypt cloud content/index/HEAD; authenticated random-access chunks, immutable multipart retries, recovery envelopes, Keychain custody, private recovery kit and explicit unlock | `EncryptedDriveCodec.swift`, `EncryptedStorageRemote.swift`, `EncryptedDriveState.swift`, `DriveEncryptionKeyStore.swift`, `DriveEncryptionSetupView.swift`, `EngineMain.swift` |
| Qualification | Secured path-resource contract validation, FSKit readiness report, adapter signposts, fixture identities, repeated rename distributions and retained failure reports | `scripts/`, `CloudDriveFSVolume.swift`, `Tests/Signing/` |

## Availability proof

Offline indicators checksum-verify at most 16 MiB of clean chunks per response, across the requested nodes. Files beyond the remaining verification budget and recursive directories show unknown rather than imply full offline availability. Missing or corrupt completed-pin chunks show attention. Current staged writes also remain unknown in this cache-only indicator. The pin request itself remains durable independently of disposable cache files. Search and activity badges are app surfaces; this does not supply Finder badges.

## Recovery details

Recently Deleted is an explicit app action. It moves live nodes into `.bucketdrive-trash-v1` using ordinary durable namespace operations, retaining payload references and open-handle identity. Its wrappers encode deletion time and original parent identity, so managed recovery preserves restore information. Compatible re-import can lose original parent IDs; restore then falls back to the root. Empty wrapper directories remain. There is no automatic expiration, purge button or Finder Trash interception. Retained files continue using cloud storage. The feature does not promise undo for ordinary Finder deletion.

New encrypted setup checks an empty prefix before binding a key. Remote recovery authenticates the candidate key against encrypted HEAD before persisting selection, so a wrong valid kit cannot poison the connection. Selection intent precedes Keychain mutation; interrupted key saving can resume using the kit. A missing key or corrupt marker prevents plaintext fallback. Recovery kits are explicitly **bearer secrets**, saved privately with file and directory durability checks; they are not password-protected backups.

New launch intents retain the macOS boot-session identity. An interrupted pre-identity launch remains fail-closed on the same boot; a later boot can establish that the old owner cannot survive and allow recovery without deleting namespace data. Older records without this identity can still need manual diagnosis. No unknown live owner is killed merely because its descriptor is missing.

## Validation and evidence

Final consolidated verification: 448 Swift tests passed, one keyboard-focus test skipped because the desktop was locked, zero failures; 33 Python checks passed. App and both extension builds passed. Both packaged-engine storage modes passed their subprocess fixtures. Final results and command logs are retained under `build/helumi-parity-current/` (local build evidence, not a production release). See `VERIFICATION.md` in this directory for the consolidated run and artifact identity.

New regression coverage includes truthful/stale status, stable search selection, URL/path validation, trash crash/replay/collision and both-mode byte preservation, 150 relocations plus return to earlier identity, legacy receipt encoding, managed upload concurrency/frontier/pause, split-extent limits, recovery budgets, authenticated encryption/tamper/CAS/range/multipart retry, full encrypted namespace recovery, interrupted key save, wrong-kit rejection and occupied-prefix refusal. No real Keychain items are changed by the setup tests.

## Limits and gates at the first implementation checkpoint

This is **not complete Helumi equivalence or a production-qualified native release**.

- At this checkpoint, signed FSKit activation was blocked by the missing matching Apple provisioning profile (resolved in the November 5 follow-up). The FSKit extension compiles; that does not prove activation or Finder IO. FinderSync compilation/packaging likewise does not prove that macOS enabled the extension.
- Live R2 conditions, mounted Finder operations, cold-launch URL routing, actual offline workflows, sleep/wake and sustained 100 GiB workloads still require qualification with the installed signed candidate and disposable remote fixtures.
- Safe >5 GiB ordinary-key copy/publication remains unsupported where required provider preconditions cannot be established. Managed immutable uploads remain a different path. No conditional operation was weakened to claim compatibility.
- Compatible remote operations remain serial. Managed content preparation is parallel, but HEAD commits remain serial. Adaptive bandwidth scheduling and independent small/large/pin lanes are not implemented.
- Bounded flat extents and recovery admission are safeguards, not a paged million-node recovery or extent-tree rewrite. Large-scale memory/disk guarantees remain unmeasured.
- At this checkpoint Finder status badges were not implemented; the follow-up added the read-only availability attribute and bounded Finder consumer. Xattrs, symbolic links and hard links retain the existing unsupported behavior. Full editor/save-pattern compatibility is unqualified.
- Encryption covers remote storage; local cache, staging and metadata remain plaintext under Mac file permissions/disk protection. Master-key rotation, encrypted ordinary-key server export, cryptographic-journal GC, provider rollback protection and independent cryptographic review are outstanding. Copying readable files out through the mounted drive remains the ordinary local export path after mount qualification.
- Transfer stop/export recovery, detailed per-byte namespace progress, adaptive upload policy and exact reference animation matching remain beyond this implementation. Pause/resume and durable accepted data are preserved.

Sharing, public file requests and hosted account/subscription work are excluded by the user's clarification. No production bucket was migrated, no existing data was encrypted, no app was installed over the user's current app, and no release was deployed.

## November 5, 2026 follow-up: permanent removal and provisioned extension

The earlier missing-profile and absent permanent-delete UI entries are historical observations. The current implementation adds explicit all-selected-item confirmation and durable acknowledgment for permanent removal from Recently Deleted. FSKit provisioning now succeeds with the existing pinned signer. Onboarding distinguishes packaged components, approval and a confirmed connection; legacy bucket testing waits for active or recoverable moves. Exact evidence and remaining installed qualification are recorded in [personal drive completion](../PERSONAL_DRIVE_COMPLETION_2026_11_05.md). Previous suite counts above are not a claim that these subsequent changes were covered by that run.
