# Finder grouping and adoption of an existing R2 drive

November 6, 2026. Native FSKit personal drive on macOS. The reference is the installed arm64 OrbitFS extension, not a model of a network filesystem.

## What the reference establishes

In the native disassembly (retained locally), the adapter branches to OrbitDrive.rename at 0x1000123ec, the rename implementation calls the local tree update at 0x1000ab9c8 and 0x1000aba14, and OrbitAPI.move branches to an item update at 0x10005c194. [Symbol mapping and interpretation](06-RENAME-MOVE-AND-COLLISIONS.md). These calls support a stable ID, destination parent and name. The disassembly does not expose Helumi's server transaction or prove how it handles a crash.

## Why this changes the Finder experience

On the old personal mount, moving twelve selected folders across prefixes required listing many more objects, copying them under different R2 keys, then removing old keys. “New Folder With Items” contained 765 entries below the twelve immediate items. File bytes have no reason to change in this operation.

The native volume acknowledges a move after a local transaction records the new parent/name and durable journal entry. Descendants retain their parent IDs. Background publication updates immutable index pages and conditionally advances the remote root. Repeated writes to a file can publish the last consecutive accepted generation together, subject to the dependency frontier and retained open handles. Separate Finder operations may be accepted while earlier work publishes. Conflicts and dirty operations must remain visible until resolved.

## Migration and recovery

1. Check the legacy owner, pending uploads, recovery journal and writable file handles. Use normal eject and wait for the exact worker to retire.
2. Import only names, sizes and backing locators. Bind each imported file to its existing R2 key and validator. Handle case collisions and reserved keys before enabling writes.
3. Build immutable metadata pages in checkpointed batches of up to 4,096 nodes. Compare-and-swap the remote root only after the complete tree is present. Record the managed capability before enabling local mutations.
4. After restart, use the saved managed mode and authenticated owner. After local state loss, recover from the published managed root. Re-importing original object keys would resurrect obsolete names. Local operations which have not published still require their original working state.

On the existing drive, 11,845 original entries (431 directories; 118,965,763,111 bytes) matched the imported index with no missing paths or size differences. Three separately obtained R2 file digests matched reads through the new personal mount, including an imported path with a colon. macOS created its own filesystem event records after mounting. The old NFS worker retired before the new mount accepted writes.

## Acceptance evidence and boundaries

The exact Finder menu action grouped twelve existing folders with 765 descendants in 1.250 seconds on CloudDrive build 39 and 0.994 seconds on Helumi. All names moved; twelve distinct test payloads backed the 765 file records. The [saved grouping result](evidence/native-finder-grouping-r2.json) records independent R2 payload checks and normal eject. These timings are single observations. See [reproducible comparison and evidence](../DEVELOPMENT.md#finder-grouping-qualification-on-november-6-2026) and [Finder writeback](../FINDER_WRITEBACK.md) for the separate oversized-file test. Multi-terabyte payloads, arbitrary Finder merges, and whole-app equivalence are not established by a grouping benchmark.

## Build and upgrade on this Mac

Use a single installed extension path throughout live tests. Launching signed scratch bundles with the same ID at different paths can cause launchd error 165 and terminate already active development mounts. An apparently correct pluginkit listing was insufficient while Launch Services still knew about the scratch application. With CloudDrive volumes ejected normally, run `python3 scripts/register-installed-finder.py --retire-build <path-to-inactive-build/CloudDrive.app>` for the eligible checkout builds after installation (repeat the option for multiple paths). This retains the signed bytes, unregisters the inactive applications and registers the single copy in Applications. Then launch normally and verify the mounted volume, an authenticated owner, and independent file contents. Never rotate registered copies during a transfer.

## Separating move, copy and publication costs

Moving an already-indexed folder changes its parent. Copying a new Logic project, in contrast, creates each directory and file and preserves macOS metadata. In build 40, an identical generated Logic package with 12 files of 32 KiB in 24 nested directories took 5.565 s in CloudDrive and 1.483 s in Helumi. This timing is the Finder copy; the later verification work, including test-only moves inside the generated package, is excluded. The numbers do not describe an existing-project move.

In the generated test, all 37 source nodes carried macOS provenance metadata. Decoding 35 AppleDouble files on the CloudDrive mount found zeroed FinderInfo and a provenance attribute in each. A Helumi test preserved the attribute without an accessible AppleDouble file. Treating FinderInfo as empty or suppressing companion files would not preserve these bytes. A second cost was verifying the peer on every local owner connection. A signed socket probe measured roughly 1.2 ms per call before reusing the kernel-audit-token-bound code handle, and 0.11 ms after; the live signing requirement is still evaluated on every connection, and a wrong bundle ID from the same developer team was rejected.

A separate restart failure was reproducible even with the right extension registered. Normal eject leaves an empty private mount directory. The old controller called Foundation's non-recursive directory creation on every reconnect; that call fails with Cocoa error 516 when the directory already exists. Mount setup now accepts an existing empty directory only when its owner, type and permissions match, and refuses symlinks or hidden/local contents. The lifecycle regression exercises all of those boundaries.

## Preserving Finder metadata

Native metadata support is opt-in per item at creation. A managed file or directory created by the new extension can store selected Finder attribute bytes alongside its stable ID. Setting an attribute updates the journal and the published node record. Create-only, replace-only, delete, absent values and retry retain the distinctions that macOS expects. A rename retains those bytes. Read-only availability is computed separately; it is not user metadata. Attribute data is bounded to 4 KiB per value and 6 KiB per item. Unknown names and genuine resource forks continue through macOS's limited-attribute fallback. The feature does not claim general support for every extended attribute or ACL.

Existing/imported nodes keep their previous metadata representation. The extension will not take over an existing companion file, or allow a rename that would obscure a conflicting one. A new managed format version prevents an older reader silently dropping native metadata. Ordinary-object export refuses a snapshot containing native metadata before writing destination keys; Finder copy to a Mac-formatted volume remains the metadata-preserving export path. Managed R2 recovery reconstructs these attributes directly from the published records.

## Measured copies of new files (build 44)

A generated Logic project containing twelve 32 KiB files in 24 nested directories copied through Finder in 1.849 seconds. The same source took 1.295 and 1.445 seconds in two warm Helumi runs. Both drives returned all twelve expected hashes without visible AppleDouble companions; CloudDrive’s published R2 manifest and contents were verified independently.

For a dense 224 MiB file on normal local storage the Finder copy took 4.580 seconds on CloudDrive and 0.810 seconds on Helumi. In a separate constrained test, the entire native engine working volume had only 160 MiB total capacity. Finder accepted the 224 MiB copy in 32.073 seconds, and independent R2 readback verified the full file digest by 88.507 seconds. These tests verify bounded staging on a real volume; they do not time a hundreds-of-gigabytes transfer. All three generated R2 scopes were cleaned up and independently listed empty.
