# Verified writeback read cache and amortized reclamation

The managed writeback path retains its complete-object checksum verification, but now shares successful reads through `VerifiedCloudObjectCache`. Cache identities include object path, validator, length and checksum. Concurrent requests for the same identity await one fetch. Invalid responses and checksum failures are never cached. The cache retains up to 64 MiB, evicts least-recently-used objects, and admits at most eight concurrent fetches of at most 8 MiB each. It is disposable process memory and does not prove cloud publication or change dirty-data retention. Reclaimed writeback objects are removed from the cache.

Previously, each `ContentStore.overlay` invocation could refetch a complete packed cloud object for a small read, even if another invocation had just verified it. Staged snapshots now reuse verified bytes across invocations, including concurrent Finder reads. Cold cache misses still fetch and verify the full immutable object; this preserves the existing integrity contract.

Ordinary sync completions now reclaim after 32 operations and at the end of each batch, rather than walking the complete pending journal after every operation. Completion receipts remain durable before reclamation. Delaying cleanup retains extra data; it does not allow early deletion. Existing lease, pending-snapshot, and remote-object ownership proofs still govern cleanup. Successful batch cleanup clears an earlier retry error so a recovered queue can return to idle.

Status polling also uses scalar SQL counts grouped by state/error plus the earliest pending error, instead of deserializing up to 10,000 operation payloads on every poll. This preserves retry/attention phase selection, reports the full queue count beyond 10,000, and removes a second repeated JSON scan from the worker's status path. The regression fixture supplies 10,005 rows with deliberately opaque payloads to prove status counting does not decode them; complete rows are excluded and null attention errors are retained.

Verification on November 6, 2026:

- All 171 core tests passed after the cache and reclamation change.
- All 62 sync-engine tests passed after adding the cold-reopen integration check: sixteen concurrent 4 KiB reads of a spilled packed object require exactly one remote read and return exact bytes.
- The cache regression checks concurrent fetch sharing, eviction/refetch, invalid-response retry, checksum separation and validator changes.
- The final focused offline-retry regression passed with explicit idle-phase and cleared-error assertions.
- The status-summary regression verifies a pending count above 10,000, attention errors and exclusion of completed rows without decoding payloads.
- Optimized engine builds and certificate signing/continuity checks passed.

The live measurement artifacts are retained under `build/helumi-upload-analysis-20261106/` and `build/writeback-cache-update/`. These intervals contain different file sizes and copy phases, so their counts do not establish a controlled overall speed ratio. Serialized metadata publication and sequential multipart parts remain separate limits; this change does not claim line-rate uploads.
