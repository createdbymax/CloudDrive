# Local third-party modifications

The bundled backend is based on rclone v1.75.2 (MIT) and go-nfs v0.0.4 (Apache-2.0).

Modified for CloudDrive on November 3, 2026:

- Optional allocated-byte support in go-nfs preserves the logical file size and legacy fallback behavior.
- Rclone exposes per-file VFS cache allocation and its NFS adapter reports physical local cache blocks.
- Missing cache data reports zero; inspection errors retain a conservative logical-size fallback.
- No upload, remote storage format, cache eviction or content signing behavior is changed by these allocation patches.

Patches and tests are retained under vendor/patches; rebuild provenance is recorded in RCLONE_BUILD.json. Upstream licences remain in RCLONE-LICENSE.txt and GO-NFS-LICENSE.txt. This personal build is not an unmodified upstream release.
