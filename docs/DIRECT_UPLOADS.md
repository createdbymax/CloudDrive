# Recovering older direct uploads

Direct upload reads existing files from their original drive and sends them to R2. Large files use resumable multipart requests; new files up to 8 MiB use a faster single request. It does not copy payloads into the Finder mount, the Mac's cache, or a temporary payload folder. The source originals are retained.

This implementation is in the local source tree and a signed local Release build. An authorized existing queue has completed against R2, preserving its saved progress, and Finder mounting was verified afterward. It has not been publicly released or qualified with a real 400 GB R2 transfer. See the qualification scope below before relying on it for irreplaceable data.

## New transfers

Drag the file or folder into its destination in Finder. For the current R2 drive, Finder can copy a new file larger than the space available to the local cache. See [Finder writeback](FINDER_WRITEBACK.md). The following controls describe existing direct-upload queues created in earlier releases.

## Pause, restart and recover

**Pause** cancels active requests while retaining confirmed parts and the queue. An in-flight part may need to be sent again. Reopen CloudDrive with the original source drive connected and choose **Resume**. Saved uploads do not automatically resume on launch.

The uploader stores the multipart upload ID, fixed part size, part checksums and confirmed part numbers. Resume checks R2's part listing against the ledger, reuses matching confirmed parts, and sends missing parts. If R2 accepted a part just before its local acknowledgement was lost, the uploader can recover it after checking that part against the source bytes.

Final completion is verified using object size, an upload-specific metadata identifier and the multipart checksum. If a completion response was lost, recovery checks whether the object was already committed before re-uploading. A progress bar reaching its end is not by itself a completion receipt.

For new nonempty files up to 8 MiB, the fast path saves the expected whole-file checksum and upload identity before a conditional single PUT. This avoids multipart initiation, part listing and completion overhead. A lost response is reconciled through the final object's identity, size and checksum. If an interrupted small PUT did not commit, only that small file restarts. Already-created multipart sessions stay multipart, regardless of file size. Large-file resume is unchanged.

Changed or substituted source files are rejected. Reconnecting a different disk with the same volume name does not establish source identity. Keep the original file unchanged until the upload has completed.

R2 normally aborts incomplete multipart sessions after seven days, but a bucket's lifecycle policy may differ. CloudDrive does not change that policy. If the session has expired, **Check expiration…** in the file’s expanded details first checks whether it is gone; only then can a new session start. Parts deleted by R2 cannot be resumed and must be sent again.

To cancel a file, pause the queue, expand its details and choose **Cancel file**. CloudDrive aborts that file's known multipart session. If the final object was already committed, it is retained. Cancellation never deletes the source original. **Clear finished history** removes local finished/cancelled records, not remote objects.

## A 400 GB file and low local storage

A 400 GB file uses 64 MiB parts, or 5,961 parts for 400,000,000,000 bytes. The scheduler uploads four files concurrently by default, with up to four rolling part requests per file. One shared 256 MiB budget admits payload buffers across the whole run, rather than multiplying that amount by the number of files. New parts refill available slots immediately. Networking, hashing, UI and runtime overhead are additional; this is not a hard total-process RSS limit. If an object requires a part larger than 256 MiB to fit the 10,000-part limit, the run budget rises to fit that one required part, and admission reduces parallelism accordingly. Files are limited to R2's 5 TiB object size and 10,000 multipart parts.

Use **Settings → Transfers → Parallel file uploads** (or **… → Parallel uploads**) to select 1, 2, 4 or 8 files. Pause before changing it, then Resume. Four is the default; eight may help fast SSDs and connections, while one or two can reduce competing seeks on a hard drive. The setting is shared by dashboard and menu uploads and does not reset saved parts. The card reports how many files are uploading and waiting.

No 400 GB local payload copy is needed. A small writable records location is still necessary for reliable recovery:

- By default records are kept under CloudDrive's private Application Support directory.
- Before queueing uploads, use **… (upload options) → Use external records folder…** to keep records on a writable external drive. The app creates a private `CloudDrive Upload Records` folder in the selected location. Use a filesystem that supports private Unix ownership and permissions, such as APFS. An exFAT volume may be a source, but it is unsuitable for records when it cannot enforce those checks.
- Keep that records drive connected as well as the source drive. They may be the same drive.
- If the saved records location is unavailable, reconnect it or use **Recover Upload Records…** to select the existing records folder. Do not create a new queue as a substitute for lost records.

The queue uses SQLite with full synchronous transactions, an exclusive owner lock, and a bounded database. It contains filenames, source identities, access bookmarks, destination fingerprints, upload IDs and checksums; it does not contain file contents or R2 secret keys. Treat the folder as private. Do not manually modify it while the app is running.

This avoids file-sized staging when the internal disk has little space. A completely full macOS startup disk can still prevent app launch, Keychain operations, ordinary OS writes or swap. The feature cannot guarantee OS operation with literally zero writable internal space. A full internal-disk workload still needs isolated qualification; do not fill your real startup disk as a test.

## Supported files and limits

- Existing resident regular files on identifiable local/external volumes are supported. Cloud placeholders and promised/unsaved drag representations are not supported as storage-free sources.
- The queue supports up to 10,000 files including retained history. Folder enumeration is limited to 100,000 entries and 64 levels. Clear finished history or upload smaller batches if a limit is reached.
- Overlapping drops are deduplicated. Symbolic links, packages, unsupported special files and cross-volume descendants are skipped and reported. Empty folders are not preserved as empty remote directories.
- macOS service folders such as `.Trashes`, `.Spotlight-V100` and `.fseventsd` are skipped. Ordinary files are uploaded as ordinary R2 objects; this is not a filesystem backup format. Resource forks, ACLs, hard-link relationships, Finder metadata and package semantics are not preserved.
- Only one actively writing Mac is supported. Finder and direct uploads are serialized in this app. This does not coordinate with unrelated remote clients or another Mac writing the same prefix.
- Direct upload rate limiting reserves payload capacity across all concurrent requests before allocating/sending their payloads. The configured rate is shared across files rather than applied separately to each file. It is request admission pacing, not an instantaneous wire-byte shaper; automatic transport retries can add wire traffic. At low limits a large part can wait before it begins. Resume uses the selected rate for that run.

## Implementation and qualification scope

The direct path is a native Swift S3 multipart client using CryptoKit SigV4 signing and an ephemeral foreground `URLSession` with capacity for eight connections per host. It does not use rclone's transient job IDs for resumability and does not change the mounted drive's object format. The actor-owned queue controls work, destination leases and durable transitions; SQLite stores job metadata and per-part records. A separate actor per source file serializes seek/read/check sequences so file reads do not block other files' queue work. Source identity is checked before/after reads and before final completion. Ordered, revisioned snapshots update the UI at most ten times per second, with an authoritative final flush after all requests drain. The speed display samples actual PUT-body send callbacks twice per second over a rolling five-second window; it is separate from confirmed/durable progress and includes retransmitted payload bytes.

Automated synthetic tests cover part recovery after an engine restart, lost completion acknowledgement, recovering a remotely accepted part, missing remote parts, changed sources, expiry handling, cancellation, zero-byte files, source-folder handling, destination binding and request signing. A sparse logical 400 GB recovery test restores 5,959 confirmed parts and reads/uploads only the two missing high-offset parts (98,279,424 bytes), then verifies the final receipt. Metadata remains below 8 MiB. This does not transfer the entire 400 GB or establish real external-drive throughput.

An independent Python loopback S3 fixture also verifies actual URLSession requests, SigV4 signatures, payload SHA-256/MD5, multipart pagination, final assembly, retries, redirect rejection, response bounds, and embedded errors returned with HTTP 200. Rendering tests exercise the native card in light and dark appearance without using the owner's credentials or drive.

Broader R2 fault interoperability, a complete 400 GB transfer, APFS/exFAT unplug/replug behavior, controlled throughput/RSS measurements, and a full internal-startup-disk scenario remain qualification work. No deployment or provider-side configuration change is implied by these tests. The existing-queue compatibility observation and JSON metadata-compression fix are recorded in [verification](DIRECT_UPLOAD_VERIFICATION.md).
