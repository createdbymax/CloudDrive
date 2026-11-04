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
