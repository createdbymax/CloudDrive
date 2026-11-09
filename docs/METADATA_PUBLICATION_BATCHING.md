# Durable metadata publication batches

Build 51 batches a contiguous journal prefix of up to 32 create, write and metadata operations into one managed publication. The selected endpoint is recorded as `managed-batch-end` before provider work starts. The exact prepared publication is retained as `managed-batch-intent` before the conditional HEAD update. New writes arriving during a retry cannot change that boundary.

The planner stops at rename/remove operations, attention barriers, local-only mutations, previously prepared individual publications and existing folded-write checkpoints. It does not split a long contiguous Finder write run into intermediate full-file uploads; those retain the existing write-folding path. Publication groups also bound the number of metadata records. The 32-operation limit keeps the encoded publication receipt within the existing journal validator-size allowance.

For each file in a batch, only its last selected write generation is prepared. Up to eight file payloads are prepared concurrently. Final node records incorporate the last accepted metadata and parent snapshots in journal order. Prepared content is not publication: no pending member can advance until its metadata commit is confirmed.

After the conditional cloud publication, final content locators are recorded durably. All batch completion states, intermediate-generation retirement receipts, and the local published frontier advance in one SQLite transaction. A failed local completion leaves the whole batch replayable, even if HEAD already committed. Reconciliation uses the frozen commit and existing upload receipts. Existing leases and pending generations continue to protect data from reclamation.

The manifest publisher applies each publication's edits to the hash trie in bulk. Repeated edits to a shared leaf or ancestor produce one final immutable page instead of uploading intermediate versions for every operation. Directory-name collision checks preserve the order of edits within the publication. The on-cloud manifest format is unchanged.

The owner remains the only HEAD publisher. This change reduces request count; it does not introduce conflicting concurrent HEAD writers. A pending publication carrying the new batch receipts should be recovered with build 51 or later, particularly if the cloud commit succeeded before local completion. Keep the new engine available for recovery rather than relying on an older build to interpret new receipt steps.

## Verification

All **525 tests** passed: 176 core, 340 app, and 9 filesystem adapter tests.

New checks establish:

- Six Finder files with 24 create/write/metadata operations publish through **one HEAD update and two metadata pages**, with six final payload uploads.
- Cold namespace recovery points to the exact final bytes and metadata; an older open generation remains readable through its lease.
- A remote commit followed by a rejected local completion cannot partially advance the batch. Reopening the journal reuses the uploaded payloads, completes the frozen batch, then publishes a subsequently accepted append.
- More than 32 operations form separate bounded batches. Rename and remove operations retain their ordered barriers, including recovery of a lost HEAD response.
- Updating 128 file records in an already branched trie rewrites at most 40 metadata pages, rather than rewriting shared ancestors per file. A cold reader verifies all updated records.

Existing tests also cover pause after preparation, concurrent upload bounds, folded-write recovery, conflicting HEAD publication, offline recovery, namespace moves, deletion, encryption, and garbage-collection retention.

Live measurements and the running engine identity are retained under `build/metadata-batching/`. File sizes and copy phases vary, so operation rates and wire throughput must be reported separately. Batch receipt counts confirm whether the running worker is actually using the new path.
