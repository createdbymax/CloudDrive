# Helumi upload architecture and CloudDrive bottlenecks

Inspected November 6, 2026. This is a static investigation of the installed Helumi and a source/profile comparison with CloudDrive. No Helumi process was launched, instrumented, or modified; no account data was read. The existing CloudDrive copy and upload worker were left running.

## Target and evidence

- Helumi **0.3.18, build 45** (installed app plist).
- Filesystem executable: `/Applications/Helumi.app/Contents/Extensions/OrbitFS.appex/Contents/MacOS/OrbitFS`.
- Universal executable SHA-256: `ec9aa769087937afa289b9c70c9b468fd32eb035c959ea232c8c48b747cd40d0`.
- Selected ARM64 slice offset: 4,341,760; UUID `07F8C48F-B905-3019-B8E6-7C5ADE56A22B`.
- REA Mach-O inventory: parent Evidence `ev_a229f7268d7bbfa4470ba5cf26a7d803894d9057be5bbff74d20929907daef46`; summary `ev_0cc83e446ec6f6f76f5e205a7a1f2a47dd1bffebd0a102ac4f6a59c1b6ca7840`.
- Complete retained REA Evidence exported to `build/helumi-upload-analysis-20261106/rea-evidence.json` before closing the session.
- Supplementary local Xcode tools: `nm -arch arm64 -n`, `swift-demangle`, and `llvm-objdump --macho --arch=arm64 --disassemble`. Their outputs, function-start inventory, and selected annotated assembly regions are in `build/helumi-upload-analysis-20261106/`. These local outputs are not REA Evidence records.

The installed artifact differs from the older 0.3.13/build 39 described in the original implementation plan. Addresses below belong to this build's ARM64 virtual-address space.

Deep decompiler providers were unavailable: Ghidra was not configured and the configured Hopper launcher was missing. REA's GNU-objdump wrapper selected Apple's LLVM objdump, which rejected its GNU `--disassemble=SYMBOL` syntax. That failed observation is preserved as Evidence `ev_a7f9138df671ccb33b42381ac14ce3f34cf97c25e1655a9750140426c7d93349`. Local LLVM disassembly succeeded with its native Mach-O arguments. No setup/configuration changes or engine installation were needed for the supported static inspection.

## What the shipped code establishes

| Finding | Exact evidence | Boundary |
| --- | --- | --- |
| Separate small-file, large-file and metadata concurrency configuration | Default initializer getters at `0x10001ab0c`, `0x10001ab14`, `0x10001ab1c` return **6**, **4**, **8** respectively (`mov w0, #constant; ret`). Symbol identities are `Configuration.smallUploadSlots`, `bigUploadSlots`, `metadataSlots`. | Observed declarations/default machine code. Actual runtime overrides, scheduling fairness, and simultaneous use of every slot were not measured. |
| An 8 MiB small-file limit and 128 MiB direct-transfer minimum | `Configuration.smallFileLimit` at `0x10001ab04` returns `0x800000`; `directTransferMinSize` at `0x10001ab24` returns `0x8000000`. | Observed defaults, not proof that every file takes a particular transfer path. |
| Chunk-oriented cached content reads | `ChunkStore.defaultChunkSize` at `0x10001aac0` returns **1 MiB**. Symbols include `ChunkStore.get`, `put`, `contains`, and `ContentReader.read(offset:length:)`. The reader region calls `ChunkStore.contains` at `0x10003a89c` and `trim` at `0x10003bc20`; another code site calls `ChunkStore.put` at `0x100040930`. | Cache participation is observed. Eviction correctness, fetch coalescing, hit rates, and every async continuation remain unverified. |
| Local staging on the Finder write path | The `OrbitDrive.write` region calls `Staging.write` at `0x1000a72e8`, then `DriveTree.update` at `0x1000a7468`. `Staging.read` at `0x1000f0fa0` uses `NSFileHandle`. | Selected local path is observed. This does not prove every write is network-independent or establish crash durability. |
| Identity-based metadata service interface | Symbols include `OrbitAPI.move(id:name:parentId:)`, `update(id:name:parentId:modifiedAt:)`, `DriveNode.remoteID`, `contentVersion`, and `metadataPending`. | Observed client API. The server's storage implementation, atomicity, batching and consistency contract remain unknown. |
| Upload feedback/pacing mechanism | `UploadGovernor.adjust(rtt:throughput:at:)` at `0x100109a54` calls `record(rtt:at:)` and `baseRTT`, compares values, and returns an optional rate. `UploadPacer` and `PoliteUploads` are declared. | Static feedback logic is observed. Its effective rate and role in the user's previous speed observation were not measured. |

These findings support a design with separate work classes, local staging, cached reads, and metadata addressed by stable IDs. They do **not** establish a measured Helumi throughput or a speed ratio for the current copy. In particular, 6 + 4 + 8 declared slots is not evidence of 18 active file uploads.

## Why raising CloudDrive's file concurrency did not solve this workload

### 1. Staged cloud reads bypass the cache

`SyncEngine.swift:119–139` routes staged snapshots through `ContentStore.overlay` instead of `RangeCache`. `ContentStore.swift:384–389` downloads the **entire cloud extent** and hashes it on each `verifiedBytes` call. `overlay` retains only one `previousObject` during that individual invocation (`ContentStore.swift:545–553`); reuse ends when the invocation returns.

Packed writeback objects can hold up to **8 MiB / 256 members** (`ContentStore.swift:324–340`). A 4 KiB member read can therefore require an 8 MiB object GET, and a subsequent call can repeat that GET. Concurrent readers do not share an in-flight fetch on this path.

CloudDrive already has validator-fenced **1 MiB** chunks and shared in-flight tasks in `RangeCache.swift:158–200`, but that implementation does not cover these staged extent reads.

The earlier live sample measured approximately **856 MB received and 2.4 MB sent over 30 seconds**. The worker sample `/tmp/bucketdrive-copy-worker-sample.txt` includes `NamespaceOwner.execute → SyncEngine.readValue → ContentStore.overlay → verifiedBytes → S3StorageRemote.read`. This corroborates interactive staged-data readback during the slow copy preparation. It does not attribute every downloaded byte to one specific repeated extent.

**Change to implement:** a bounded verified-object cache with shared in-flight fetches keyed by immutable identity, validator, length and checksum. Keep complete-object checksum verification before admitting an object to the cache. Simply replacing this path with unchecked range reads would weaken the current integrity contract. Do not retain every historical object indefinitely.

### 2. Cleanup repeatedly scans the backlog

`SyncEngine.swift:486` invokes `reclaimPublishedLocalData` after each ordinary operation; the batch end invokes it again. `OperationJournal.swift:474–493` scans the content inventory and JSON-decodes pending operation payloads to establish snapshot ownership. This repeats work proportional to a backlog of over ten thousand operations.

The worker profile includes `processPending → reclaimPublishedLocalData → snapshotInventory → JSONDecoder`; 516 sampled frames appear in pending-operation decoding. This is a sampled stack count, not a comprehensive CPU percentage.

**Change to implement:** amortize reclamation across a bounded batch, elapsed interval or storage-pressure trigger. Persist publication and completion receipts as today; postponing deletion should retain extra proven data rather than delete it early. Longer term, maintain transactional references so reclamation does not decode the complete pending queue repeatedly.

### 3. File uploads still feed a serial metadata publication path

`SyncEngine.swift:917–933` prepares and publishes an operation through the shared managed publisher. `ManagedManifest.swift:117–135` writes metadata trie pages, a commit and the conditional shared HEAD. The publisher accepts up to 256 operation IDs, but the current caller supplies singleton IDs.

Helumi's metadata-slot declarations and ID-based remote API differ from this single shared client publication frontier. This is an architectural distinction; the installed client does not reveal its server implementation.

**Change to implement:** journal a fixed ordered publication group and its exact intent, publish the group with one conditional HEAD update, reconcile uncertain replies, then complete its members transactionally. Preserve dependencies, snapshot retention and replay. Running concurrent HEAD publishers would introduce conflicts rather than safely parallelize this work.

### 4. Scheduling can still block ready small work behind large work

`prepareManagedBatch` waits for the selected group of payload preparations before ordered publication. Multipart parts inside a file remain sequential (`S3StorageRemote.swift:415–423`). More file slots help some workloads, but do not eliminate these boundaries.

**Later change:** independent bounded small/large preparation queues with publication advancing only across a safe ready journal prefix. Consider parallel multipart parts under an explicit shared memory budget after the dominant readback and metadata costs are addressed.

## Recommended order

1. Verified staged-object cache and concurrent-read coalescing.
2. Amortized cleanup with the existing retention proofs intact.
3. Durable metadata publication groups.
4. Separate small/large scheduling and qualified parallel multipart parts.

Qualify each change with an independent resumed Finder copy, measured outgoing payload bytes and completed files over time. Keep local copy admission, prepared immutable payloads, published cloud state and reclamation as separate measurements. A 1 Gbps uplink has a theoretical ceiling of 125 MB/s before protocol overhead; these static findings do not establish that either app saturates it.

## Investigation coverage

- **Answered statically:** current artifact identity, declared concurrency defaults, chunk size, selected local write/staging path, client metadata interface, and presence of upload feedback logic.
- **Answered from CloudDrive source and prior runtime samples:** uncached staged extent fetches and repeated journal-inventory cleanup; serial shared-HEAD publication is established by source.
- **Partial:** complete Helumi scheduler execution and cache behavior; async/indirect paths and runtime overrides remain unresolved.
- **Unresolved:** matched live Helumi throughput, server implementation and guarantees, exact contribution of each bottleneck to total elapsed time, and post-fix CloudDrive performance. No new CloudDrive implementation changes or deployment were made by this investigation.
