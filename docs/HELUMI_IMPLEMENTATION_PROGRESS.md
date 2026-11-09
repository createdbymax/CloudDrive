# Helumi-style implementation progress

Updated November 5, 2026. Scope: `HELUMI_FILE_MANAGEMENT_IMPLEMENTATION_PLAN.md`. Source implementation and qualification are tracked separately below.

## Preserved baseline

The legacy signed `.6` backend remains available. No live bucket conversion was performed. The Photos recovery journal is preserved: 8,700 inventory objects, four verified-copy receipts, zero source-deletion receipts at the recorded baseline. Synthetic tests use separate generated storage.

## Implemented

| Phase | Current source behavior |
|---|---|
| P1 | Shared core, stable UUIDs and persisted inodes; SQLite durable transactions, journal, receipts, MVCC and exclusive ownership. Rename changes namespace rows without walking descendants or waiting for cloud I/O. |
| P2 | Compatible overlay with captured historical paths, dependency ordering, copy/verify before conditional deletion, durable recovery, protected staged snapshots and retained open-file generations. |
| P3 | Native FSKit callback adapter and separate owner executable, authenticated bounded IPC with reserved metadata capacity, private mount resource, strict mount ownership, independent Finder eject reconciliation and safe worker retirement. Real extension builds against the installed SDK. |
| P4 | Uploads, search, local/cloud status, pin/unpin/free-space and storage accounting route through the selected namespace owner. Read-only selections prevent legacy upload fallback. |
| P5 | Managed immutable content and hash-trie metadata, conditional HEAD publication, conflict stop, pinned-HEAD recovery and restartable ordinary-key export. Managed uploads reference verified immutable keys without a final content-copy step. |
| P6 | Explicit metadata preview/import, checked checkpoints, mode capability records, legacy work admission gates, recovered read-only selection, durable launch intent, process/signature ownership, persistent pause and updater/quit safety. Packaging embeds and signs the owner; extension inclusion requires a valid matching Apple profile. |
| P7 | Fault tests for unknown replies, process restart, stale samples, range integrity, replacement/unlink leases, multipart reconciliation, corrupt records, disk/accounting protection and IPC backpressure. Generated native process checks cover compatible and managed modes. |

The app saves accepted metadata changes locally before background publication. This makes a same-drive move responsive; cloud completion remains separately visible. Cross-volume copies still transfer bytes.

## Qualification and remaining release gates

- Signed FSKit activation and real mounted Finder move/edit/eject testing remain unperformed. No installed FSKit provisioning profile was found. Manual Xcode provisioning with the existing pinned signing identity required an FSKit profile; automatic signing with the same explicit certificate conflicted with automatic provisioning. These results do not establish that the developer account cannot issue a profile.
- The existing signing identity is preserved. The unsigned extension build is not an activated filesystem. A packaged candidate without that extension must not advertise native mounting as available.
- Live isolated R2 CAS, conditional delete, multipart/lost-response and external-writer qualification remain required. Loopback tests independently check HTTP and SigV4. Compatible write admission now probes positive and negative conditional DELETE behavior on a generated private object before enabling it; proof is connection scoped and expires.
- Native compatible server-side copy is not yet qualified for objects above the provider single-copy limit (5 GiB). Multipart **upload** is implemented; multipart **copy** is a separate remaining task. Large compatible moves must not be advertised as qualified.
- Staging manifests are bounded and safe, but repeated sequential generations still rewrite flat extent metadata. Sustained 100 GiB workloads, long outages, measured memory/disk pressure and power-loss testing remain necessary before claiming the full P7 targets.
- Search offers keep-downloaded/free-space actions. The optional FinderSync badges/context-menu extension is not implemented. Actual Finder refresh after owner-originated uploads and macOS 26/27 behavior need signed mounted qualification.
- Remote work is ordered conservatively. Bounded IPC gives metadata reserved capacity, but the complete throughput/scheduling acceptance matrix is not qualified.

## Reproducible checks

Run `swift build --product CloudDriveEngine` before lifecycle tests: `swift test` alone can leave a stale standalone executable. Then run `swift test`, `python3 -m unittest discover -s Tests/Signing`, and both modes of `scripts/qualify-namespace-engine.py` against that explicit executable. Build the native extension with `scripts/build-fskit-extension.py`; packaging rejects a missing or mismatched FSKit profile rather than using an ad-hoc fallback.

Fresh results and artifact paths are recorded in `HELUMI_VERIFICATION.md`. None of these synthetic checks authorizes converting the retained legacy bucket or discarding pending data.

## November 5, 2026 follow-up: personal drive and provisioning

The earlier missing-profile blocker is superseded by a successful FSKit provisioning run with the existing pinned signer. Recently Deleted now has explicit multi-item permanent-removal confirmation, and FinderSync menu integration exists in source. These statements do not retroactively change earlier test results or imply native mounting was qualified. See [personal drive completion](PERSONAL_DRIVE_COMPLETION_2026_11_05.md) for exact provisioning evidence, UI test limits, deletion semantics and pending installed qualification; see [FSKit setup](FSKIT_SETUP.md) for corrected packaging instructions.
