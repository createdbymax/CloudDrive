# Automatic metadata catalog updates

CloudDrive starts automatic catalog updates after launch once a valid connection is loaded. Search stays local and works without Finder. There is no requirement to leave the search window open or manually refresh after ordinary app uploads or Finder edits.

## Update paths

- **Direct uploads:** verified receipt persistence and a metadata outbox hint commit in the same upload-record transaction. A background consumer transfers hints into the catalog's durable change queue before acknowledging them. Clearing completed history does not remove undelivered hints. Existing verified upload history is backfilled on recovery; acknowledged hints are not recreated.
- **Finder:** the patched storage worker exposes an authenticated `vfs/metadata-changes` read-only feed. File publication, file removal and file/directory rename paths emit invalidation hints. The existing owned-worker status poll captures them about once a second. Catalog reconciliation normally runs every two seconds, using HEAD for exact keys and paginated LIST for affected directory subtrees. These intervals are scheduling defaults, not latency guarantees under network or transfer load.
- **Outside changes and recovery:** automatic complete reconciliation discovers mutations made by other clients, handles older workers and repairs feed/session/retention gaps. It runs approximately every 30 seconds below 10,000 entries, two minutes below 100,000, 15 minutes below one million, and one hour at larger scale, plus scan time. An unfinished baseline is resumed or safely restarted. These are periodic observations, not a cross-device conflict-resolution service.

Eject captures a final feed page after pending uploads drain and before stopping the worker. A failed or incomplete final capture requests automatic full reconciliation; metadata failure never blocks safe eject. A currently running older worker is preserved rather than replaced. It uses periodic reconciliation until a normal safe eject/reconnect launches the new backend. Metadata-feed failure never changes mount ownership, upload completion status or recovery gates.

## Truth, ordering and durability

Worker events are hints, including when a rename/remove operation fails or has a partially completed remote outcome. They do not directly create verified objects or delete catalog entries. Current LIST/HEAD facts decide the result. For a large disappearance discovered by a full scan, two complete inventories must agree on the absent key set at the same mutation revision before individual absence checks may remove entries. The signature is hashed in bounded pages so search can interleave. A changed revision invalidates that confirmation. HEAD 404 permits a local tombstone; permission failures, malformed replies, redirects and timeouts stay pending. No cloud mutation or file-content download is performed by indexing.

Each worker feed has a random VFS-instance session, ordered sequence numbers, a 4,096-event retention bound, at most 256 events per response and an encoded-response size budget. The feed is process-local, not an fsynced remote transaction log. Once read by the app, pending hints and the consumed cursor commit atomically to SQLite. Process replacement, event loss or a gap schedules a complete reconciliation. A crash after a remote change but before a worker hint is captured is repaired by the automatic scan.

Catalog schema version 3 migrates older catalogs in place. It adds a monotonic mutation revision, pending changes, per-key change versions, a worker checkpoint and bulk-absence confirmation state. New hints invalidate old full-scan generations, so late LIST/absence responses cannot overwrite a newer edit or publish false freshness. Targeted operations compare queued revisions; a late HEAD or acknowledgement cannot consume a newer same-key hint. Durable deletion versions also block a late parent-directory listing from resurrecting an already deleted key, including one never previously cataloged.

Directory moves reconcile old and new scopes with exact segment boundaries. Unseen known descendants are confirmed individually. Updated descendants take precedence over older parent hints. Different sides of a rename may become visible progressively; cloud copy/delete is not an atomic rename transaction. Results and counts publish during larger updates so the window does not wait for an entire subtree to finish.

Duplicate worker deliveries are idempotent. Duplicate direct-upload delivery is safe because the queue coalesces keys and rechecks current facts. Failed keys rotate behind unattempted work so one denied object does not indefinitely block unrelated changes. Pending-check failures retry with backoff up to one minute. Low space, unavailable records/catalog storage and offline conditions preserve durable work and saved search results.

## Controls and limitations

The search window shows automatic-update state. **Pause indexing** or **Pause automatic updates** stops reconciliation but keeps received hints durable. **Refresh index** / **Resume automatic updates** resumes it. Pause is session-local; reopening the app enables updates again. **Start fresh scan** remains available for diagnostics, not routine edits.

Search itself makes no network calls. The background updater makes metadata requests while running. File contents remain subject to Finder connectivity and existing upload/cache rules. Large directory changes, long offline periods or a saturated worker feed can require a longer reconciliation; this implementation does not promise immediate knowledge of arbitrary outside writes.

There is no server-side Queue/Worker deployment, remote sidecar format, Spotlight integration, full-text extraction or second writer. Upload records retain their existing FULL synchronous durability, ownership checks and source-file recovery requirements.

## Qualification

The automated tests cover in-place catalog migration; legacy upload backfill; receipt/outbox atomic rollback; history-clear/restart/lost-ack delivery; duplicate worker pages; cursor/queue atomic rollback; session changes and gaps; stale scans and HEADs; deletion resurrection races; subtree rename boundaries; fair retries; automatic baseline/external-change discovery; and automatic delivery with no manual refresh.

The native NFS fixture copies, renames and removes real files and renames a directory through an isolated Finder-style mount, then observes automatic catalog results. It asserts ordinary file changes do not trigger a root inventory scan and verifies the feed rejects an invalid control credential. It uses synthetic source files and a local-backend stand-in, never the user's drive or R2 keys. macOS AppleDouble sidecars are treated as actual remote objects; logical-file assertions use exact keys rather than assuming only one filename match.

The worker tests exercise retention, paging, replacement sessions, response-size limits and concurrent readers/writers, including Go's race detector. The pinned upstream archives and patch hashes remain checked by the backend builder. See [qualification results](LOCAL_SEARCH_VERIFICATION.md) for final run totals and remaining limits.
