# Additional Helumi speed gaps — November 6, 2026

## Scope and evidence

Read-only comparison; no installed app, copy, cloud configuration or upload policy changed. Helumi had updated since the previous inspection: current version **0.3.20/build47**, OrbitFS universal SHA-256 `3536875b25cf8c3d233488310f3ffd8d33b9ef3d3d908683e2445b8019603409`, ARM64 UUID `48854D36-A655-35D5-A9C8-C8A323DEC36A`. Rechecked current artifact identity before using its code. REA Mach-O parent evidence `ev_d1689982350c17f20a36432fa6596b743ce5bfed72be5895b33ec233ee5cb8be`, exported in `build/helumi-speed-gaps-20261106/rea-evidence.json`; session closed after export.

Supplementary Xcode nm/demangling, LLVM disassembly, indirect symbols and dyld fixups are retained in that directory. Native decompiler remains unavailable; observed machine-code paths and declarations below are distinguished from scheduling/server hypotheses. Historical snippets in its `historical-0.3.18` subdirectory do not describe current addresses.

## Additional live hot path: per-byte HTTP response collection — first fix

S3StorageRemote.request126–140 uses URLSession.AsyncBytes and iterates a byte at a time, performing Task.checkCancellation, a size comparison and Data.append for every byte. The current worker sample has528 samples under the verified staged-read task, including520 under S3StorageRemote.read/request;269 samples at request139 include168 Data.append frames. A further150 samples at request138 include91 cancellation checks and63 OS availability checks. Stack samples overlap and are not CPU percentages, but they establish costly byte-processing work on the active path rather than merely network wait.

Helumi's current Mach-O imports include NSURLSession.data(for:delegate:), upload(for:from:delegate:) and download(for:delegate:). Imports alone do not prove which API handles a particular read; its disk cache path is established separately below. Therefore the per-byte diagnosis is a source/profile-proven CloudDrive bottleneck, not a claim that every Helumi response uses a particular implementation.

**Proposed improvement:** use bounded chunked response delivery, such as URLSessionDataDelegate buffering with early status/Content-Length validation, a strict received-byte cap, cancellation propagation and the current mutation-outcome classification. Avoid replacing the loop with unbounded data(for:) and checking size only after allocation. Qualify oversize/chunked/truncated responses, cancellation, invalid statuses, lost mutation replies and parallel requests. This is a smaller change than redesigning the filesystem or publication format.

## 1. Disk-backed cache for staged cloud data — high priority

**Helumi, observed:** ChunkStore.get at ARM64 `0x10003033c` constructs a cache path via `0x100030550`, checks its index under a mutex, and calls `0x1002890c8` at `0x100030450`. The stub loads GOT `0x10034c968`; dyld fixups bind this to Foundation Data.init(contentsOf:options:). ChunkStore.put at `0x100030e30` calls stub `0x100289188` at `0x100030f24`; GOT `0x10034c9f0` binds to Data.write(to:options:). This establishes a disk-backed content cache, not just a class name.

**Ours, source:** RangeCache already persists normal published-file chunks with a default5GiB budget. The gap is specifically spilled/staged extents: ContentStore.verifiedBytes uses VerifiedCloudObjectCache, whose retained cache is64MiB in RAM, with8 concurrent fetches. A copy that scans a larger working set or restarts can download those immutable objects again after eviction. Increasing the normal RangeCache budget does not fix that path.

**Proposed improvement:** add a bounded disk tier for fully verified writeback objects, keyed by immutable path, size, validator and checksum, with shared in-flight fetches. Preserve complete-object verification before returning member ranges, validate local cached bytes, handle corruption/cache removal safely, and account for clean cache separately from dirty data. This should reduce repeated downloads during Finder resume and final assembly; actual cache miss counts and before/after bytes must establish benefit.

## 2. Direct in-memory metadata reads — high priority

**Helumi, observed:** getAttributes `0x10000f260` calls helper `0x100018df0` at `0x10000f2b8`. The helper calls DriveTree.node `0x1000679e8` at `0x100018e84`, builds attributes at `0x100018ee8`, replies at `0x100018f18`. The tree getter locks at `0x100067a10`, looks up its dictionary at `0x100067a24`, and unlocks at `0x100067ab8`. No IPC/database/network occurs in this successful path.

**Ours, source:** CloudDriveFSVolume.getAttributes calls the owner. NamespaceIPC.exchange creates/connects/authenticates a new socket and encodes each request. NamespaceStore.node queries SQLite and walks ancestors to establish visibility. Directory list selects IDs then invokes rawNode separately for every entry (NamespaceStore.swift:62–85). These repeated operations amplify many-small-file workloads.

**Proposed improvement:** first fetch listing rows in a single SQL query and reuse bounded prepared statements inside the authoritative owner actor. Then add a coherent owner metadata read index and persistent authenticated RPC or a revision-fenced extension view. Update/invalidate on all app, Finder, remote, rename/delete and recovery mutations. An unvalidated TTL cache can return stale sizes or visible tombstones and is not a safe substitute.

## 3. Separate rolling preparation lanes — high priority

**Helumi, observed defaults:** an8MiB small-file threshold and separate small/large/metadata slots6/4/8 at current ARM64 `0x10001ac24–0x10001ac40`. These declarations establish distinct work classes; they do not prove effective runtime fairness or18 active uploads.

**Ours, source:** SyncEngine.processManagedPublicationBatch at953–969 launches a window of8 payload preparations and waits for every result before starting the next window. Metadata preparation/publication follows all payload windows at971–991. A slow item can leave completed slots idle. At423–427 a settling write also ends the eligible prefix for the whole pass.

**Proposed improvement:** rolling refill on each completion; bounded small/large queues; let immutable preparation look beyond a busy node while one publication coordinator advances only the dependency-safe prefix. Retain shared HEAD CAS ordering and durable batch recovery. Per-node/subtree publication dependencies would be a larger later change; do not launch racing HEAD writers.

## 4. Reuse streamed upload bytes for final publication — potentially largest byte saving

**Ours, proven source gap:** ContentStore uploads early spill packs and removes redundant local members. Later SyncEngine.prepareManagedContent903–915 reads the complete snapshot and uploads a final object. Spilled bytes can therefore be uploaded, downloaded for assembly, and uploaded again. The RAM cache reduces repeat GETs but does not eliminate the second outgoing transfer.

**Helumi, observed interface only:** current symbols include uploadStreamBlob `0x10010666c`, commitStream `0x100106948`, commitStreamContents `0x100106d94` and uploadBlob(...partDone:) `0x1001070a0`. This establishes a separation of byte transfer and namespace commit. Its server-side composition, copying and guarantees remain unobserved; we cannot claim it never retransfers data.

**Proposed improvement:** reusable durable multipart parts or versioned composed immutable references, rather than treating spill objects only as intermediate storage. Requires a larger storage/recovery design: random overwrites/truncation, out-of-order writes, checksums, uncertain replies, stale upload sessions, retained-reader snapshots and cleanup. Do not recycle parts solely because byte offsets match.

## 5. Parallel multipart on the native upload path — concrete gap, Helumi parity unproven

S3StorageRemote.swift415–423 reads/uploads each multipart part serially, limiting one large file to one part request at a time. The separate direct uploader already has rolling part slots with memory admission at DirectUploadEngine.swift293–319 (up to4). Reuse that qualified pattern under a shared budget across files, rather than multiplying8 files by4 unbounded buffers. Helumi part concurrency was not established by the available static evidence, so this is a source-derived improvement, not a claimed Helumi feature.

## What is already present

CloudDrive already has local staging, stable IDs, sparse writes, batched durable metadata publication, verified read coalescing, and retained HTTP connection pooling (one URLSession with8 host connections). Do not report these as missing. Helumi's delayed-save and upload-delay declarations do not establish equivalent crash durability; reducing fsyncs without a recovery design is not supported by this comparison. Mount icon/path changes have no proven throughput benefit.

## Recommended order and qualification

1. Remove per-byte HTTP response overhead, preserving bounded response memory; then measure and fix staged-object disk caching and directory SQL amplification for the current resumed copy.
2. Rolling size-separated preparation, with a single ordered publisher.
3. Shared-budget native multipart parallelism for large-file throughput.
4. Durable streamed-content reuse to remove redundant transfers.

Use controlled wide/deep directory and small/large file workloads as well as the user's live copy. Track local admission latency, completed files, verified final payload bytes, incoming/staging traffic, and publication independently. No causal speed gain is claimed for these unimplemented proposals.

## Current live workload check

A90-second read-only observation of the unchanged build51 worker, with the build52 filesystem adapter, saw687MB newly staged (7.57MB/s),662writes across10nodes,7.78MB/s outgoing and8.09MB/s incoming traffic. Publication completed128operations and45objects (3.26MB final payload), with4metadata batches and no errors. Dirty file nodes fell862to828 while dirty logical bytes grew23.18to23.86GB. Incoming/staging traffic and final payload are distinct; file count improvement does not imply the byte backlog is shrinking. The profile supports prioritizing bounded response buffering and staged-cache reuse. Full samples and analysis: `build/helumi-speed-gaps-20261106/diagnosis.md` and `summary.json`.
