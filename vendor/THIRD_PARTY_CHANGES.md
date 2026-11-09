# Local third-party modifications

The bundled backend is based on rclone v1.75.2 (MIT) and go-nfs v0.0.4 (Apache-2.0).

Modified for CloudDrive on November 3, 2026:

- Optional allocated-byte support in go-nfs preserves the logical file size and legacy fallback behavior.
- Rclone exposes per-file VFS cache allocation and its NFS adapter reports physical local cache blocks.
- Missing cache data reports zero; inspection errors retain a conservative logical-size fallback.
- No upload, remote storage format, cache eviction or content signing behavior is changed by these allocation patches.

Patches and tests are retained under vendor/patches; rebuild provenance is recorded in RCLONE_BUILD.json. Upstream licences remain in RCLONE-LICENSE.txt and GO-NFS-LICENSE.txt. This personal build is not an unmodified upstream release.

The rclone metadata-changes patch adds a bounded authenticated VFS invalidation feed for CloudDrive's local metadata catalog. It records hints around publication, removal and rename operations without changing remote object formats, upload durability or filesystem results. The corresponding patch and focused concurrency/retention tests are included in `vendor/patches/0003-rclone-metadata-changes.patch`.

Modified for CloudDrive on November 4, 2026:

- The go-nfs rename patch preserves moved file/directory handles and rebases descendants, invalidates replacement handles, serializes compound handle-cache updates, and bounds ancestor lookups by path depth. Optional native request leases coordinate handle resolution with rename/recovery. Write handles close on error paths.
- The rclone safe-moves patch adds opt-in destination-bound private move journals, synced per-object copy/delete receipts, authenticated move status/recovery, native mutation leases, busy-cache checks, collision validation and rename replay handling. Folder moves preserve cached node identities and refresh their remote objects. Server-side remote moves copy/verify the complete inventory before deleting sources; partial moves retain records and block native mutation until explicit recovery. This changes remote move behavior when `--vfs-move-journal` is enabled, and does not change remote object formats.
- Source files, regression tests and the full patch series are included in the corresponding-source archive. These changes are CloudDrive modifications, not claims of upstream rclone/go-nfs support or production provider qualification.

November 6, 2026. The concurrent-moves patch assigns independent move journals to disjoint paths, validates overlapping writers and keeps the original single-slot journal readable. The R2 copy patch adds a conditional destination write and operation receipt for moves requested through CloudDrive. The protected move also carries a validated AppleDouble sibling through its durable copy and verification phases. Source patches and regression checks accompany the backend.

The November 6 NFS creation patch serializes same-parent create and mkdir admission and checks exclusive-create replay against the server-observed inode and request verifier. The bounded receipt table lasts for one worker process. A missing receipt on an occupied path returns an existence error. The patch includes tests for competing clients, retries and replacement.

Worker `v1.75.2-clouddrive.9` avoids requesting every child's last-modified timestamp and allocation during a directory name listing. NFS READDIR emits the same file identifiers as GETATTR. READDIRPLUS retains file handles and can omit optional attributes on regular files backed by a provider with expensive modification times. Targeted LOOKUP and GETATTR still return complete metadata. The added protocol regression test decodes replies, checks 64-bit and fallback file identity, and checks the absence of metadata fetching on the deferred path.


Worker `v1.75.2-clouddrive.10` adds bounded Finder writes to the personal R2 mount. The worker writes verified immutable ranges to a private namespace before reclaiming local APFS blocks, uses a durable index to recover after interruption, and verifies the final ordinary object before collecting temporary ranges. Full replacements, writes to existing cold objects, sparse appends and concurrent disjoint writers share the cache budget. Conditional marker creation reduces round trips during folder copies. Finder deletion now defers during uncertain publication and preserves the local copy when provider deletion fails. The patched sources and the corresponding regression tests are included in patches 0011 through 0014.
