# Finder writeback for the personal R2 drive

## Native indexed Finder drive

The FSKit volume stores item identities, parents and pending changes in a local database. Moving a folder changes its parent; its descendants continue to point to that same folder. Finder can observe the new location while the owner publishes metadata to R2. No payload copy is necessary for that rename. Finder can still perform individual operations for merges, replacements and copies between volumes.

Existing objects imported during setup remain the backing for their files. New content and the published index use private keys under the selected prefix. Manage names through Finder; do not remove private keys or old backing objects from the R2 dashboard. For recovery after loss of local state, use the managed-drive recovery flow and its published index rather than importing the raw keys again.

For large copies the owner keeps a bounded set of dirty ranges locally, verifies remote writeback ranges before releasing local space, and reads those ranges during final publication. The working index must stay on a writable local disk. When offline or short of working space, Finder may have to wait or report a write error. Use `scripts/qualify-native-bounded.py` to measure an actual Finder copy on a small APFS volume and verify publication independently. Use `scripts/qualify-native-finder-project.py` to time copying and grouping separately.

## Measurements on the installed native build

On build 40, Finder copied a dense 224 MiB file from outside an APFS volume with a 159.96 MiB hard limit on all of the test owner's local state. Finder returned after 34.302 s; the owner finished publication and the independent R2 download and verification were complete by 104.506 s. [Saved measurement](helumi-parity-2026-11-05/evidence/native-finder-hard-cap-r2.json). Maximum measured volume consumption was 46,284,800 bytes (44.14 MiB). The verified R2 SHA-256 matched the source. The test volume ejected normally, its owner stopped, and an independent listing confirmed zero remaining test objects after cleanup. The personal volume was also mounted during the copy. Build 38 had taken 138.307 s to accept the same size before writes were grouped.

The native limit for one file is 624 GiB with the current multipart design. A separate test exercised the indexing of a 320 GiB file with 65,537 extents; it did not transfer a 320 GiB payload. The capped test exercises real remote spill rather than extrapolating from sparse or zero-filled files.

## Legacy NFS mount: how bytes reach R2

Small files stay in the normal cache. As a new file or a full replacement exceeds its share of the volume's dirty cache budget, the worker seals 4 MiB ranges. Every range gets a SHA-256 name under a private R2 sibling prefix bound to the endpoint, bucket and mounted root. The worker records its intent, uploads the range with a transport checksum and verifies its receipt. It syncs its local recovery index before releasing APFS blocks. Offline writes can wait or fail once the available local budget runs out.

Finder reads and the final uploader use the same combination of local bytes, remote ranges and logical zeroes. The final uploader streams one ordinary object, downloads it again to verify its checksum, then records cleanup of its private chunks. The binding marker persists for future copies. Cleaning up chunks and re-reading the finished object incur R2 requests and bandwidth. The path currently supports generations up to 4 TiB, with up to 1,048,576 distinct chunk hashes per generation.

The worker budgets local payloads across concurrent writers. The app chooses a window between 8 MiB and 256 MiB and the worker reduces its allowance under disk pressure. Filesystem metadata, cached reads and already-existing files consume additional space. The capped-volume qualification covers copying a new file, overwriting overlapping ranges, truncating and regrowing the file, and appending after local eviction. Other edit patterns need separate qualification.

## Recovery

After interruption, reconnect to the same drive and keep its local cache. The worker checks the cache binding, committed extent index and backing file before resuming writeback. Missing or corrupt recovery metadata requires keeping the cache for diagnosis. Reinstalling an older worker must use its separate cache location. Never erase the cache or its private R2 prefix to clear a pending transfer.

The local metadata stores a checksummed cursor into an append-only extent index. A change writes records for just the affected ranges. Startup verifies the committed prefix and ignores any tail left by an interrupted metadata commit. A simulated 300 GiB extent index test exercises reopen, incomplete writes, byte corruption and the fixed 45-byte cost of dropping one mapping.

## Reproducing the limited-space test

Use `scripts/qualify-bounded-finder.py --help` for the macOS qualification harness. It uses generated data, an isolated APFS disk image, a separate mounted worker and a unique R2 test namespace. The hard volume cap makes the storage constraint reproducible without filling the Mac’s startup disk. The harness compares the original SHA-256 to a separate download of the finished R2 object and checks cleanup of its generated keys.
