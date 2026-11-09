# Native upload speed fixes — November 6, 2026

This update applies the concrete source/profile findings from HELUMI_ADDITIONAL_SPEED_GAPS_2026_11_06.md. It retains the existing cloud publication format, ordered shared HEAD, namespace ownership, local acknowledgements and recovery receipts.

## Changes

- **Bounded HTTP chunk collection.** Replaced S3's URLSession.AsyncBytes per-byte cancellation/append loop with URLSessionDataDelegate response chunks. Status validation occurs before accepting the body; declared length and actual chunk bytes enforce the response cap (HEAD's object length is handled separately). Cancellation resumes one continuation once, redirects stay disabled, and session/task creation is serialized with close so an invalidated session cannot receive a new task. S3's read failure and mutation unknown-outcome classifications remain intact.
- **Verified staged-object disk cache.** Added a disposable 1 GiB disk tier behind the existing maximum 64 MiB RAM cache and eight shared fetches. Immutable path, length, validator and checksum form its identity. Disk hits are fully hashed, corrupted/missing files fall back to remote reads, and symlink/directory replacement cannot redirect cache IO. The private cache has bounded inventory/eviction and a free-space reserve. It is separate from dirty writeback admission and never proves publication or authorizes dirty-data deletion.
- **One directory query per page.** Fetch complete listing rows in the page SELECT, sharing the exact node decoder with direct reads. This removes one prepared query per child while retaining pagination, dot inodes, revision, tombstoned ancestor checks, snapshots, backing locators and xattrs. No unvalidated extension metadata cache was introduced.
- **Rolling, size-classed file preparation.** Refill completed file slots immediately within the existing frozen publication batch. Mixed work has separate small/large lane limits of six/four under an eight-file ceiling; one class can borrow spare slots. Reader-range admission is bounded. Errors or pause stop new admission, and already admitted payloads settle their durable receipts before the single publisher continues.
- **Rolling native multipart parts.** Each file can prepare up to four parts, under a shared per-remote ceiling of four active parts and 128 MiB of admitted part payloads across all files. One coordinator persists successful part receipts; failure stops refill and drains admitted tasks while retaining successful receipts. Existing upload IDs, lost-reply reconciliation and expired-session behavior remain. These are payload admission bounds, not a claim about total Foundation/process memory.

## Verification

Meaningful coverage includes declared/chunked response limits, HEAD lengths, HTTP failures, redirects, cancellation, close racing new task creation, parallel response isolation, cache corruption/removal/restart/identity isolation/eviction/low space/concurrent readers/symlinks/replaced directories, paginated deep/wide namespace listings and tombstones, rolling lane fairness/refill/pause/failure, shared multipart byte/request budgets, and lost multipart creation/completion/publication replies. An 80 MiB fixture upload proves the fifth part starts while its first part is still blocked.

The pre-existing cold packed-object read test now removes the disposable disk cache before reopening, retaining its intended cold-fetch/coalescing assertion. Separate new tests verify that a warm disk cache avoids that GET across restart.

## Scope limits

This update does not replace the owner with Helumi's in-extension in-memory tree, publish out of dependency order, or change final content into composed spill references. Early spill data can still be downloaded and uploaded again for final assembly. Eliminating that transfer requires a separately qualified content/recovery format change; this update reduces repeated reads and their CPU cost while preserving the current integrity contract.

## Live measurement

A fresh 60.49-second pre-update sample (engine 51, host/adapter 52) measured 16.341 MB/s outgoing traffic, 16.193 MB/s incoming, 9.013 MB/s final uploaded-receipt payload and 8.001 MB/s newly verified staged data. There were 480 new writes across 21 nodes and no journal errors. Current dirty logical bytes increased 28.160 to 28.645 GB while Finder copied. These workload observations are not a controlled benchmark; file mix and partial-copy readback affect the comparison. Artifacts are under build/speed-fixes/before-*.

Full `swift test` passed:547tests (340app,10FSKitadapter,197core), zero failures. Log: `/tmp/bucketdrive-speed-all-tests.log`.

Installed local signed build53 and verified the running engine digest. A90.53-second startup/readback sample had zero new writes,159completedoperations,29uploadedobjects and nojournalerrors. It does not establish activecopy throughput. The old AsyncBytes/Data.append hotspot was absent from its5-secondworker sample. Post-install artifacts: `build/speed-fixes/after-startup-*`.

## Build 54: parallel verified spill packing

Build53's first active observation improved final uploaded payload modestly (9.01→10.57MB/s) but did not improve staging admission (8.00→5.93MB/s in differing file mixes). A separate60.65-second pack-specific observation confirmed56verified packs/467.8MB,7.71MB/s, median completion gap1.01seconds and at most one unverified intent. Therefore the copy path still had a serialized8MiB PUT→HEAD→verifiedGET→receipt pipeline even though final uploads were parallel.

ContentStore now reserves disjoint members synchronously and runs at most4packing jobs/32MiBselected payloads. Any completion can free local admission space; capacity and free space are rechecked after suspension. Background refill waits for8MiB,256members, or a full next-extent boundary; pressure can flush partial packs. Failed jobs requeue still-local unmapped members and surface failure without deleting dirty data. Active cloud groups and local members stay pinned against reclaim. The durable receipt-before-mapping-before-unlink protocol and on-cloud format are unchanged. Deferred refills capture no completed payload buffer.

Four dedicated tests verify overlap/caps, blocked-first/out-of-order completion and rolling refill, failed verification/retained local accounting/retry, exact cold reads, leftover local files after durable receipts, and partial packing under a256KiBquota. Reopen testing exposed a shutdown ownership race: SQLite is now explicitly closed before releasing owner.lock, including failed-initialization cleanup. Deferred-refill callbacks are included in quiescence. The previously intermittent reopen test passed12/12separate process runs; an explicit-close test verifies12replacement SQLite connections while the old closed object remains alive.

Final build54 checks passed:201core tests+10FSKit adapter tests, zero failures. The previous build53 full suite passed547tests including340app tests. Logs: `/tmp/bucketdrive-parallel-spill-final-tests.log`, `/tmp/bucketdrive-speed-all-tests.log`. Build54 source changes over53 are limited to ContentStore, ManagedExtentIndex and the dedicated regression tests. Live serial baseline artifacts: `build/helumi-speed-gaps-20261106/serial-pack-*`.

Build54 Release engine compiled and staged host/engine signatures passed deep strict verification and the installed app's designated requirement. Activation was blocked by the macOS lock screen; build53 remained installed/running with the current copy undisturbed. Unlock requested before any further Finder operations.

Build 54 was installed after the Mac was unlocked. The installed bundle passed deep signature verification; the restarted worker's executable hash matched the signed bundle. The namespace journal was backed up before replacement. Library and Documents already matched the source by file path and size, and Finder had no active copy window. The Downloads destination was empty, so its visible contents were started in Finder without recopying Library or Documents. Finder reported uncopyable items; the remaining items continued. This is not a full backup verification.

The live build 54 sample verified 271 new spill packs (2.210 GB) in 82.20 seconds from the first observed in-flight pack: **26.89 MB/s**, versus **7.71 MB/s** in the previous serial packing sample. Four packs were observed in flight, with 2,468 new write operations and no journal errors in that active window. The two live samples used different file mixes. The 125.37-second observation including copy preparation averaged 17.63 MB/s of verified spill payload and completed 128 journal operations. That stage throughput measures verified temporary R2 packs, not final file publication or completion of the Downloads backup. Artifacts: `build/parallel-spill-update/active-comparison.json`, `live-summary.json`, `live-runtime.jsonl`, and `live-network.csv`.
