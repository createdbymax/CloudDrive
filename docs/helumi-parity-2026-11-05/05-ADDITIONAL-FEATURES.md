# Additional functional parity workstreams

These are proposed BucketDrive implementations, not reconstructed Helumi server internals. Current Helumi UI and shipped feature names motivate the scope; exact server contracts remain unknown. Preserve direct R2 connections. Features requiring a service must be explicitly configured and must not silently upload credentials or content to Helumi or any new service.

## A. Recoverable trash

Foundation: namespace identities, operation journal and managed manifests. A hidden/deleted namespace node is not sufficient: recovery needs retained content references, original parent/name, deletion timestamp, operation ID and retention deadline.

Proposed `TrashEntry`: stable trash ID, node ID, original parent/name, content generation/reference, subtree manifest reference, deleted-at, retention-until, remote publication state. Store a subtree manifest/reference without eagerly rewriting descendants on the local acknowledgement path. Define compatible-mode retention in a reserved app-owned prefix; pre-existing buckets must opt into this layout. Managed mode retains immutable content through GC roots. Count trash separately from recent-cache usage.

Flow: move to trash commits durable local intent and hides the name; sync publishes retention before deleting any sole remote copy. Restore defaults to original parent when it exists; occupied names require explicit replacement or an alternate name. Restore after parent deletion offers a target folder. Empty-trash/purge has a clear irreversible confirmation and must not race a restore, open handle or active publication. An expired entry becomes eligible, not automatically safe, for GC.

Acceptance: crash at every publication/deletion boundary; restore nested tree; occupied destination; offline trash/restore ordering; lost remote response; GC while old generation is open; inspect all retained hashes. Expose pending/failed trash operations rather than claiming instant remote deletion. Test account reconnect and local-state loss against retained remote metadata.

## B. Sharing

Scope choices: an ordinary unencrypted single-file expiring presigned link can be a limited direct-storage feature. Passwords, revocation, stable folder shares, download restrictions, branding and audit require additional enforcement. Do not label a signed URL as a revocable share when it remains usable until expiry.

Proposed service contract: `createShare(nodeID, generationPolicy, expiresAt, accessPolicy, idempotencyKey)`, `listShares`, `updateShare`, `revokeShare`. Choose snapshot versus follows-latest explicitly; renames should preserve an ID-based link under the selected policy. Persist opaque share ID and state locally; never record access-bearing URL values in diagnostics. Server authenticates ownership, scopes all content lookups and rate-limits public endpoints. A service must receive narrowly scoped storage access, not a desktop root credential.

UI flow: select file/folder → configure expiry/access → create → copy link → manage/revoke. Show unsupported encrypted sharing distinctly. A copied link must have reached an acknowledged created state. Retry unknown create outcomes by idempotency key. Deleting the underlying file, changing generations and losing access have defined recipient messages.

Acceptance: expired/revoked link, guessed ID, cross-account lookup, folder traversal, stale generation, concurrent revoke/download, create response lost, offline management and encrypted content. Capture the same Helumi fixture workflow before deciding which semantics actually match.

## C. File requests

A request is a capability to submit new objects to a bounded destination, not permission to list/read or overwrite existing files. Proposed model: request ID, owner/destination node ID, title, expiry, allowed type/size constraints, total quota, state and opaque public capability. Server stages submissions, verifies completed bytes/checksum and publishes them through the namespace owner/import protocol. Apply actual byte limits, not browser-only checks. Colliding names get deterministic alternate names unless an explicit owner review says otherwise.

UI: Create request → configure destination and limits → copy link → list received/pending/rejected items → close request. Submitter gets progress and final receipt. Owner sees new arrivals and can reject without deleting unrelated content. Interrupted uploads need bounded expiry and cleanup of their own multipart resources.

Acceptance: oversized payload, repeated receipt, interrupted multipart, replayed capability, closed/expired request, malicious filenames, MIME mismatch, duplicate names, quota race, owner offline and concurrent local rename of the destination. Encrypted request ingestion needs a separate key-wrapping design; do not promise it as a consequence of at-rest encryption.

## D. End-to-end encryption and recovery

Live Helumi settings report E2EE and a saved recovery key. This is evidence of a user-facing feature, not proof of its algorithms, metadata protection or key custody. BucketDrive currently needs a separately specified encrypted-format and key-management subsystem; preserving plain direct-storage compatibility remains an independent mode.

Design deliverables before implementation: threat model; versioned encrypted-object format; vetted authenticated-encryption primitive; per-file/generation key derivation or random keys; nonce uniqueness under retries and concurrent writes; authenticated chunk order/length/generation binding; encrypted manifest policy; explicit remaining metadata; device enrollment/revocation; Keychain custody; backup/recovery key format; and migration/rollback protocol. Review random-access encryption with the range cache: cache keys bind ciphertext format/key version and content generation, authenticated before bytes become readable. Never overwrite the only plaintext or decryptable generation during migration.

Proposed state machine: disabled → enabling/preflight → migrating → enabled; errors pause at durable checkpoints. Recovery states: unavailable, generated-not-confirmed, confirmed, rotation-pending. A recovery-key rotation must describe which envelopes change and when the old key ceases to work. Device revocation cannot revoke plaintext already obtained by a device. Do not claim otherwise. Sharing encrypted data requires explicit recipient key distribution or carefully designed link-key handling.

Acceptance: known-answer vectors; chunk tampering/reordering/truncation; nonce uniqueness after crash/retry; wrong/revoked key; recovery on a clean device; migration interruption; concurrent upload and key rotation; local-state loss; encrypted export; no key/plaintext in logs or diagnostics. Independently review the design and implementation before an E2EE release claim. Numeric performance costs are measured, not assumed.

## Delivery order and interfaces

1. Finish engine and mounted durability gates from document 02; unify per-node command state for UI.
2. Implement recoverable trash and qualify retained-generation GC.
3. Define optional service boundary and build limited sharing, then file requests, against disposable storage.
4. Develop encrypted format/key custody as a separate compatibility milestone; enable encrypted sharing only after its own contract passes.

Suggested new interfaces are `TrashStore`, `SharingService`, `FileRequestService`, `EncryptedContentCodec` and `KeyEnvelopeStore`. These are proposals, not existing source symbols. All UI actions should use the existing authoritative namespace identity, not raw display paths. Public-link persistence and service tokens require distinct credential handling. Each milestone updates the parity ledger with observed reference behavior, implementation evidence and remaining exclusions.
