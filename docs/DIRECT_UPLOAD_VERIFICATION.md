# Direct upload verification

Local verification on November 3, 2026. Synthetic tests did not use real R2 or user credentials. A subsequent explicitly authorized app switch resumed the user's existing queue against R2 and mounted Finder after completion; no provider configuration changes, deployment, or public release publication were performed.

## Results

A full `swift test` run passed **187 tests**, with zero failures, after the concurrent scheduler, shared resources, source readers and payload telemetry changes. This includes the existing Finder/NFS lifecycle checks and the upload suites below:

| Suite | Tests | Evidence |
| --- | ---: | --- |
| `DirectUploadTests` | 18 | Persistent restart, missing parts, lost completion, source mutation, security-bookmark reopening, checksums, zero-byte files, expiry, cancellation, folders, exclusions, signing, and missing remembered records locations. |
| `DirectUploadFaultTests` | 14 | Cancellation, writer exclusion, lost initiation, expiration safeguards, admission rollback and limits, same-folder recovery, replaced/unwritable records storage, offline cancellation, and uncertain empty-file commits. |
| `MultipartTransportTests` | 13 | Real URLSession HTTP calls to an isolated loopback S3 fixture; independent Python SigV4 and payload digest verification, multipart assembly, pagination, retry policy, redirects, bad ETags, bounded responses, embedded HTTP-200 errors, conditional small-object PUT checksums/no-clobber, and actual PUT send-callback telemetry. |
| `SmallObjectUploadTests` | 7 | Single-PUT request counts and receipts, lost-response recovery, source changes, threshold boundary, retry intent and preservation of existing multipart sessions. |
| `LargeMultipartResumeTests` | 1 | Logical 400 GB recovery with a large part ledger and actual high-offset source reads. |
| `DirectUploadPresentationTests` | 2 | Native card and complete paused-dashboard rendering in light and dark appearance with synthetic saved jobs, no Keychain or provider access. |
| `DirectModeStatusTests` | 11 | Direct/Finder mode distinction and failure priorities. |
| `ConcurrentUploadTests` | 13 | File overlap/caps, rolling multipart refill, pause/restart with confirmed parts, duplicate-key exclusion, sibling cancellation, appended files, foreign destinations, ordered revisioned delivery and scheduler authority. |
| `UploadSchedulingTests` | 13 | Global payload admission, FIFO fairness, bounded waiters, cancellation/grant races and aggregate request pacing. |

`swift build -c release` also passes. The Xcode project was regenerated to include the new application sources. `git diff --check` passes.

The subsequent status/UI refinement passed **19 focused checks**: 11 direct-mode status tests, six existing status tests and two presentation tests. These cover paused/active/waiting direct uploads without a Finder mount; Finder-to-direct switching; records, destination and file errors; priority for authorization, ownership, cache and stale status failures; and complete paused-dashboard renders in light/dark appearance. The dashboard render verifies that direct Resume is available while Finder Connect is intentionally unavailable, and was inspected to confirm the conflicting disconnected status and disabled Finder controls are gone. These changes do not modify the user's queue or start any provider operation.

## Concurrent upload performance

The scheduler defaults to four concurrent files (selectable 1/2/4/8), with four rolling part slots per file and a shared 256 MiB payload budget. Payload acquisition happens inside independently completing child operations, preventing admission deadlocks; each per-source reader serializes its seek/read/check sequence. A larger required part raises the run budget only enough to admit that part, retaining support for objects whose fixed part size exceeds 256 MiB.

The eight-file benchmark with 25 milliseconds of simulated PUT delay recorded **0.294 seconds serial versus 0.080 seconds with four concurrent files**, about 3.7× in that synthetic workload. Timing is reported, not asserted. Tests assert actual request overlap, limits, integrity and recovery. This is not evidence that a real R2 connection will saturate 1 Gbps.

Real URLSession loopback testing confirms that `didSendBodyData` reports PUT payload bytes using the existing foreground transport. The UI samples that thread-safe counter twice per second over a rolling five-second window, separate from durable progress. HEAD and multipart metadata do not inflate it; retransmitted PUT bodies do count. Engine snapshots carry monotonically increasing revisions, UI updates are coalesced, and final state is forced after all request groups drain.

## Small-file performance improvement

New files up to 8 MiB use a persisted checksum intent and conditional PUT, followed by HEAD verification. Existing multipart sessions are not converted. A fresh multipart upload no longer lists its known-empty session, and each confirmed part is committed once rather than writing the same metadata twice.

The local six-file latency benchmark recorded 18 requests / 0.235 seconds for the single-PUT path versus 30 requests / 0.446 seconds for the updated multipart path, with 10 milliseconds of simulated latency per request. Timing is reported rather than asserted; request counts and final integrity are asserted. This is a synthetic overhead comparison, not measured R2 throughput or a promise of a particular speedup.

The investigation used read-only local queue summaries and synthetic tests. It did not modify or interrupt the active upload, or start provider test uploads.

## What the 400 GB test establishes

The test creates a sparse source with logical size **400,000,000,000 bytes**, uses 64 MiB parts, and commits 5,959 previously confirmed parts to SQLite. It closes that state and opens a new engine from the database.

Recovery sends only parts **5,960 and 5,961**, totaling **98,279,424 bytes**, and never initiates a replacement multipart upload. Distinct marker bytes in the missing tail confirm that the engine seeks to the correct offsets rather than rereading the beginning. The test verifies the resulting upload identity, multipart ETag, logical object size and completion receipt.

The sparse source occupies under 1 MiB of physical allocation, and the records occupy under 8 MiB. The mock remote stores metadata rather than concatenating a 400 GB payload.

This is evidence for large-file addressing, part-count handling, durable state reconstruction and missing-part selection. It is **not** a full 400 GB transfer, throughput benchmark, hardware crash test, or measurement of total runtime RSS.

## Reproduction

Run the complete suite:

```sh
swift test
```

Run the upload-specific tests:

```sh
swift test --filter 'DirectUpload|MultipartTransport|LargeMultipartResume'
```

To save isolated light/dark card renders, supply `CLOUDDRIVE_DIRECT_UPLOAD_PREVIEW_DIR` with a writable output directory when running `DirectUploadPresentationTests`. The fixture uses synthetic metadata and credentials only.

The HTTP fixture is `scripts/fixtures/multipart-s3-fixture.py`. It binds to loopback and never consumes the owner's R2 environment or Keychain.

## Remaining qualification

- Broader real R2 fault qualification, including expiration, permission failures, cancellation races and account-specific lifecycle settings. Ordinary existing-queue completion has now been observed as described below.
- An uninterrupted full 400 GB transfer and representative interrupted transfers against R2.
- Actual external APFS/exFAT source removal/reconnection, with an APFS records volume that supports private ownership and permissions.
- Throughput, total-process RSS, memory pressure and swap across different Macs and upload speeds.
- An isolated full-startup-disk environment. Metadata-only tests and an external records option do not establish that all macOS services can operate with zero writable internal space.

Keep source originals. Uploads whose parts have been removed by R2's lifecycle policy must restart; the application never silently treats such an expired session as resumable.

## Authorized existing-queue switch and Finder verification

The app was paused and its metadata database backed up through SQLite's backup API before closing the Debug process. The signed Release process reopened the same job IDs, completed receipts and confirmed parts. No folder was re-added and no records were cleared.

An existing JSON object exposed an R2 response-compression compatibility issue: metadata verification could fail when a response omitted object length or used a weak ETag. Release 0.5.12 sends `Accept-Encoding: identity`, retaining size and strong-checksum verification. A new loopback regression reproduces the missing-length/weak-ETag response when gzip is requested and verifies correct metadata with identity encoding. All 14 HTTP transport tests pass.

After that fix the original queue completed. Local receipt inspection confirmed that every previously completed receipt and confirmed part remained intact, with no missing job IDs. The native Finder mount was then connected and opened successfully, and both the app's fresh status and the system mount table confirmed it was active. Metadata backups remain in private application-support storage. This is a real existing-queue compatibility observation, not a full 400 GB transfer or a complete provider failure matrix.
