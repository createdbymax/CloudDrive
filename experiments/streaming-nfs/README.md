# Bounded streaming NFS experiment (S1)

This is an isolated feasibility prototype. **It is not the CloudDrive production backend and is never selected by app packaging.** Use only generated disposable files and literal loopback S3 fixtures. It does not consume the owner's R2 configuration or Keychain. No owner-data migration is implemented.

## What it implements

- A real NFSv3 filesystem using pinned `go-nfs v0.0.4` / billy dependencies. Each WRITE is at most 1 MiB. It uploads an immutable content-addressed ordinary chunk object, then writes/fsyncs an atomic local manifest and syncs its directory before returning success. The existing NFS adapter's FILE_SYNC response is thus backed by this operation ordering. COMMIT is not treated as file-close/publication.
- No payload file is staged locally by this engine. A serialized engine mutex admits one chunk mutation/read/publication at a time across all files, providing backpressure. Outbound committed chunks can precede the producer's completion.
- An aggregate manifest budget (default 16 MiB, maximum 32 MiB) is checked before uploading the next write. Current + candidate journal use up to twice that logical budget, plus filesystem allocation/lock/directory overhead. Exhaustion rejects a write before acknowledgement. It is a metadata limit, not a maximum final-file size or a reservation of free disk.
- Reads reconstruct immutable extents and check each chunk digest; random rewrites, sparse holes, explicit truncate and reopen after process restart are supported. Truncation removes old ranges so extending does not resurrect truncated bytes.
- Explicit authenticated `/publish` assembles a frozen snapshot into one ordinary object. S3 publication uses an additional client download/reupload with an 8 MiB multipart buffer; it is not free server-side assembly. The mutex backpressures new writes during publication. A successful Finder copy alone does **not** publish the final ordinary object in this prototype.
- The journal binds to the exact experiment store. Restart restores accepted ranges and chunk references. Remote immutable chunks are never garbage-collected or automatically expired. Failed publication leaves accepted chunks/journal available; a publication retry is explicit.

The durability contract is process-crash ordering contingent on successful object-store PUT durability and OS fsync behavior. It does not claim tested hardware power-loss safety. A remote chunk PUT followed by a crash before journal commit may leave an unreferenced chunk; that write was not acknowledged. A crash after journal commit but before the client receives the response may replay an already durable operation. Repeated writes remain byte-correct but consume additional journal entries.

## Deliberate restrictions

Root-level ASCII fixture filenames only. Directories, symlinks, hard links, remove, rename/atomic replacement, implicit truncating opens and filesystem locks are unsupported and fail closed. Recreating an existing file does not silently truncate it. This is not general Finder/editor compatibility, trash, history, encryption, multi-Mac coordination or a daily-use release.

NFS has no file CLOSE RPC. `billy.File.Close` is called once per WRITE by this adapter; it must never finalize a transfer. Publication must use the explicit control described below until a production completion contract is designed and qualified. Ordinary completed objects are readable without this engine; pending files depend on this prototype's manifest/chunk namespace and are not ordinary completed files.

The vendored adapter advertises 1 MiB reads/writes, limits READ allocation to 1 MiB and rejects RPC records over 2 MiB. Its variable-length XDR decoding is capped before allocation. Existing manifests are size-checked before reading and bounded again during reads; nonregular journals and invalid extent/size bounds fail closed on restart. The listener admits at most eight connections. Publication adds an 8 MiB application buffer and chunk reads add bounded buffers; Go runtime, journal copies, HTTP and NFS responses also use memory. Measure total RSS under concurrent workloads; these guards alone are not a proved hard total-process RAM quota. Local unauthenticated NFS remains accessible to other processes on this Mac; listeners are restricted to literal loopback. This is a trusted synthetic-client experiment.

## Build and run

Use the pinned Go toolchain archive already described in `../../vendor/RCLONE_BUILD.json`:

```sh
python3 experiments/streaming-nfs/build.py --toolchain-archive /path/to/go-toolchain.tar.gz --test
```

Or supply the pinned executable with `--go /path/to/go`. Go modules are pinned by `go.mod` / `go.sum`. Build output is ignored under `bin/`; the build does not overwrite any bundled app/backend. The script verifies the archive hash and restricts extraction to regular files/directories. Generated build/toolchain caches are private temporary directories, separate from the measured experiment state.

For a native qualification fixture, provide synthetic `STREAMING_CONTROL_TOKEN` (at least 24 characters) and `STREAMING_S3_ACCESS_KEY` / `STREAMING_S3_SECRET_KEY` through the child process environment, then start:

```text
bin/streaming-nfs --state /private/temporary/fixture/state \
  --addr 127.0.0.1:NFS_PORT --control 127.0.0.1:CONTROL_PORT \
  --store s3 --endpoint http://127.0.0.1:S3_PORT \
  --bucket fixture --prefix UNIQUE_EXPERIMENT_PREFIX
```

The S3 adapter rejects non-loopback endpoints, ambient proxies, redirects and unsafe object keys. Native test fixtures use a separate local S3 server with synthetic authentication. A filesystem-only store is available with `--store local --remote-dir /private/temporary/fixture/remote`; it is useful for ordering tests but is not evidence of S3 payload transfer.

The first stdout JSON object reports readiness, actual listener addresses, PID and limits. It never prints tokens/keys. Mount via native `mount_nfs` with explicit matching `port`/`mountport`, `tcp,vers=3,nolocks,nodev,nosuid`, and `rsize=1048576,wsize=1048576`. Do not mount over owner data.

Control requests use `Authorization: Bearer SYNTHETIC_TOKEN`:

- `GET /status`: accepted bytes, durable write count, current manifest logical/physical allocation, budget and poison state. Accepted bytes include rewrites; they are not final logical size or independent checksum verification.
- `POST /publish?name=fixture.bin&key=ordinary/fixture.bin`: explicitly assemble/publish one ordinary final object. The complete expected input length must match. Object publication is separate from accepted filesystem writes.
- `--crash-after-put`: isolated fault-injection exit 86 after the first successful chunk PUT and before its manifest update. Never use fault injection with owner data.

Stop new producer work, normally unmount, then stop only the fixture worker. Preserve failure artifacts when teardown is uncertain. Never recursively remove a mounted fixture or purge accepted chunks to meet a disk target.

## Source and tests

The final build runs 16 engine/S3 tests and four nested-module XDR bound tests. `engine_test.go` covers startup allocation/corrupt-extent bounds, accepted-byte restart recovery, explicit ordinary publication, offline PUT refusal, crash between chunk/journal, journal failure, overlapping writes, truncate/zero extension, aggregate metadata admission, concurrent write backpressure, unsupported destructive operations, corruption/store-binding refusal and oversized write rejection. `s3store_test.go` exercises actual authenticated local S3 PUT/GET/multipart publication and abort/error paths. Native-NFS, large-fixture, allocation/RSS and crash qualification results are reported separately; passing Go tests alone do not establish Finder compatibility or the full S1 exit.

The vendored `third_party_go_nfs` is the exact pinned source archive from `vendor/RCLONE_BUILD.json`, with experiment-only limits/decoder/allocation patches. Its Apache-2.0 license and original notices are retained. Production `build/backend/rclone` and production filesystem sources are unchanged by this experiment.
