# Helumi foundation comparison — 2026-11-06

Inspected installed Helumi 0.3.18 (45), OrbitFS ARM64 executable SHA-256 `ec9aa769087937afa289b9c70c9b468fd32eb035c959ea232c8c48b747cd40d0`, using REA native dispatch metadata and plist evidence. Supplemented with local Xcode LLVM disassembly and read-only observations of both mounted volumes. Retained REA evidence: `build/helumi-foundation-20261106/rea-evidence.json`. Native decompilation was unavailable; static observations do not establish runtime throughput or the cost of individual callbacks.

## Foundation and presentation

Both drives use FSKit path resources, not block-device resources. Both active mounts carry `local,nodev,nosuid,noowners,noatime,fskit`. CloudDrive additionally advertises its crash recovery journal. URL volume properties report both as local, non-removable, non-ejectable, case preserving/insensitive, sparse-capable, and supporting persistent IDs. The internal-volume URL property is unavailable for both. Finder's sidebar briefly described Helumi as an internal hard drive; its later AX state described both only as eject. Sidebar presentation is not proof of a different I/O foundation.

Helumi mounts at `/Volumes/Helumi`; CloudDrive mounts inside application support. Helumi publishes an OrbitFS personality named Helumi; CloudDrive's personality dictionary is empty. CloudDrive additionally requires security-scoped path resources. Do not remove that security boundary merely to resemble Helumi.

Helumi embeds OrbitCore inside its FSKit extension. CloudDrive delegates mutations to an authenticated separate worker with durable journaling. That worker can continue cloud publication after Finder unmounts. The process boundary is a real difference; this inspection does not quantify its cost or justify discarding the ownership and recovery model.

The shipped OrbitVolume declares FSVolumeOperations, ReadWriteOperations, OpenCloseOperations, XattrOperations and PreallocateOperations. It does not declare KernelOffloadedIOOperations. CloudDrive also uses the read/write callback path. Kernel offload is not an established Helumi advantage.

Helumi's statistics getter at ARM64 0x10000840c configures 4096-byte blocks and a 1 MiB I/O size; its maximum-file-size getter returns 5 TiB. CloudDrive uses 4096-byte blocks with requests up to 8 MiB; its managed limit is 624 GiB and compatible limit is 5 GiB. Raising our declared limit without qualifying the storage path would be incorrect.

Helumi advertises symbolic links. CloudDrive only models files and directories and correctly returns ENOTSUP for links. Durable symlink support remains a substantive parity gap requiring namespace, manifest and replay changes. Timestamp preservation is also incomplete in CloudDrive. Neither is silently represented as implemented.

## Corrected in build 52

- Set `supports2TBFiles` true. Apple's installed FSKit SDK defines this as files larger than 4 GB, potentially up to 2 TB; both CloudDrive modes qualify. The separate maximumFileSize still communicates the actual bound. Read-only getattrlist of the remounted build52 volume and Helumi confirms the large-file capability is valid and true on both.
- After successful file creation, consume the requested initial size only if the returned committed node matches it, including zero. Previously the owner applied the size but the adapter did not report it consumed. FSKit's SetAttributesRequest contract requires reporting successfully used attributes. This avoids possible redundant size application without accepting unsupported timestamps.

Eight callback tests passed, including nonzero/zero sizes, unconsumed directory size, unconsumed unsupported modification time, and failure on read-only volumes. The optimized Release extension compiled and was signed using the existing validated FSKit profile. Installed host and extension versions are 52; the upload worker code remains the previously verified metadata-batching build51 engine. Local namespace backup was retained before installation. No new permissions were added.

## Measured upload improvement

Before the adapter reconnect, a 150.5-second active-copy sample of the metadata-batching engine measured:

| Metric | Before | Batched engine |
|---|---:|---:|
| Published operations/min | 25.9 | 102.0 (3.93×) |
| Upload receipts/min | 16.0 | 31.9 (2.00×) |
| Outgoing wire traffic | 1.73 MB/s | 8.53 MB/s (4.93×) |
| Verified final payload rate | 0.0134 MB/s | 0.0297 MB/s (2.21×) |

Finder admitted 1,232 writes across 34 nodes while pending file nodes fell 1,520 to 1,468. No operation errors were present. Wire traffic includes staged objects and metadata; it is not final published payload speed. The file mix differs between samples, so these are live workload observations, not controlled benchmark results or a claim of line-rate performance. Artifacts: `build/metadata-batching/watch-summary.json`, `watch-live.jsonl`, `watch-network.csv`. Adapter fixes have no separately measured causal speed improvement yet.

## Reconnect verification

Build52 host and extension versions and installed extension SHA-256 were checked against BuildInfo; deep strict codesign verification passed. A new extension process mounted the same local volume. The durable worker remained running on the identical build51 engine binary, preserving its in-flight cache. After a short pause/reconnect, uploads resumed and Finder resumed the same Library/Downloads/Documents copy into T5 Backup (56.48 GB total). Finder reported that some items could not be copied; remaining items were continued, so this is not a claim that the backup is complete. Post-reconnect queue/network observations are retained in `build/foundation-update/`.

The 120.4-second post-reconnect sample completed 192 publication operations (95.7/minute), recorded 68 uploaded receipts and had 0 operation errors. Finder was still reading back the partial copy, with only 5 new local revisions; this sample verifies continued publication, not new copy throughput.
