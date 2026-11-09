# Local allocation attribute patches

Pinned bases: rclone `v1.75.2` (MIT) and `github.com/willscott/go-nfs` `v0.0.4` (Apache-2.0).

Apply `0001-go-nfs-local-allocation.patch` with `patch -p1` at the dependency root, then `0002-rclone-local-allocation.patch` at the rclone root. Configure a Go module replacement to the patched dependency before building rclone. Keep both original dependency licenses with the resulting package.

The dependency patch adds a structural optional `AllocatedBytes() uint64` interface to NFS attribute conversion. Ordinary file information retains the original logical-size fallback. The rclone patch wraps regular-file information from Stat, Lstat and ReadDir and derives the returned allocation from the physical `st_blocks * 512` of that exact local cache file. Logical size, inode and UID/GID remain unchanged. An absent cache file reports zero; unsafe, unsupported or unreadable cache information falls back to logical size rather than fabricating zero.

The patches do not download content for metadata requests, create cache entries, delete cache files, change upload durability, or force all files to zero allocation. Dirty cached files and partial reads report their actual allocated blocks. NFS attribute-cache mount options must also be qualified so Finder does not retain the previous allocation indefinitely.

Focused Go tests added by the patches:

```sh
go test ./... -run TestOptionalAllocatedBytes -count=1  # dependency module
go test ./cmd/serve/nfs ./vfs/vfscache -run 'TestAllocation|TestAllocated' -count=1
```

Native macOS qualification must additionally verify unchanged logical size, positive allocation during dirty writes, partial read allocation, zero after confirmed clean eviction, and correct content after reopening. Go unit tests do not establish Finder behavior by themselves.

## macOS API distinction

On the tested macOS NFS client, POSIX `stat.st_blocks` still falls back to logical file size even when the server's wire `Used` is zero. Apple's generic vnode layer synthesizes `va_total_alloc` for `stat`, whereas the NFS client returns the accurate `va_data_alloc`. Do not use POSIX block counts as the sole Finder acceptance criterion.

The isolated patched server was independently observed returning `Used = 0` on the wire, and Foundation `URLResourceValues.fileAllocatedSize` and `totalFileAllocatedSize` both returned zero for the uncached file while its full logical size remained unchanged. Native Finder Get Info remains the final UI acceptance check. Preserve this distinction when documenting results; do not claim POSIX allocation reporting was fixed.

## Automatic catalog invalidations

`0003-rclone-metadata-changes.patch` adds an authenticated, bounded `vfs/metadata-changes` feed on the same pinned rclone base. Apply it after `0002`. VFS publication/remove/rename paths record process-local invalidation hints without network/disk work in those callbacks. Responses carry a random session, monotonic sequence, gap status and bounded pages; app-side durable cursor/queue commits and automatic reconciliation handle loss/restart. Hints never prove publication/deletion. See [automatic index updates](../../docs/AUTOMATIC_INDEX_UPDATES.md). Focused tests: `go test ./vfs -run TestMetadataChanges`; concurrency qualification: `go test -race ./vfs -run TestMetadataChanges`.

## Native Finder moves

Apply `0004-go-nfs-rename-handles.patch` to go-nfs after `0001`, and `0005-rclone-safe-moves.patch` to rclone after `0002`/`0003`. Keep the go-nfs module replacement. The build script verifies every patch hash and runs focused regression tests.

The go-nfs patch adds optional rename/request hooks, atomically rebases memory-cache handles (including descendants), invalidates replacement identities, clears cached listing verifiers and removes a whole-cache scan from handle lookup. The rclone patch forwards those hooks, retains cached VFS node identities across directory moves and enables journaled copy/verify/delete with `--vfs-move-journal` and a stable `--vfs-move-binding`. Its memory-cache path is the app-supported path; disk/symlink caches retain explicit invalidation fallback behavior.

Focused tests: `go test -race ./helpers -run TestRenameHandles` in go-nfs; `go test -race ./vfs ./cmd/serve/nfs ./vfs/vfscache -run 'TestSafeMoves|TestNativeMoveReplay|TestPathRewriter|TestAllocation|TestAllocated|TestMetadataChanges'` in rclone. Native qualification: `python3 scripts/qualify-finder-moves.py --s3 --finder`. These fixtures use generated data and synthetic credentials only. See [Finder move behavior](../../docs/FINDER_MOVES.md).

Apply `0008-go-nfs-exclusive-create.patch` to the go-nfs source after the rename/handle patch. The patched worker serializes NFS exclusive file and directory creation across concurrent clients on one mount.

For `v1.75.2-clouddrive.9`, apply `0009-go-nfs-directory-identity.patch` to go-nfs after 0008, then `0010-rclone-lazy-directory-attributes.patch` to rclone after 0007. The two changes cooperate on NFSv3 READDIRPLUS. Attribute omission is opt-in per entry. The standalone READDIR identity calculation also retains the existing path hash for filesystems lacking an explicit inode.


Worker `v1.75.2-clouddrive.10` applies the following additional patches in numeric order.

- `0011` implements binding and checksum validation for private R2 writeback objects.
- `0012` adds the cache window, APFS reclamation, ranged reads, cold object adoption, crash recovery, publication verification and cleanup. It also protects dirty files during move admission and cache cleanup.
- `0013` uses conditional leaf creation when Finder creates an empty R2 directory marker.
- `0014` protects Finder unlink against active or uncertain provider publication.
