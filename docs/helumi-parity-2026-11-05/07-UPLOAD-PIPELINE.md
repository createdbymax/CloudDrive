# How Helumi uploads a Finder copy

Helumi 0.3.18 build 45 contains two separate entry points. Dropping files on its app reads local file URLs from an AppKit dragging pasteboard. Writing files into the mounted volume goes through FSKit. The latter can enter a direct-transfer path from filesystem preallocation and can leave it when writes cease to look like a plain copy. The mounted-volume decision needs no clipboard event. A keyboard paste shortcut, an end-to-end upload time and the selected path of any particular live Finder operation remain unmeasured.

The static analysis inspected the installed host and extension executables. A separate mounted Finder trial is described below. REA opened the OrbitFS Mach-O with its built-in provider. Its explicitly requested Hopper provider reported a missing executable. Spotlight, PATH and the usual local application directories yielded no Hopper installation. Apple disassembly and Swift symbol tools supplied the function-level findings. Instruction addresses below refer to the arm64 image of this build. Provider and artifact identities (retained locally) · Selected native instructions (retained locally)

## Mounted Finder comparison

On November 6, Finder copied a generated 129 MiB file from local storage into each mounted drive. Timing stopped when Finder’s duplicate command returned. Both mounted copies matched their source SHA-256. CloudDrive build 32 took 13.23 seconds. A separate download through the R2 API matched at 37.01 seconds from the start, including verification time. Helumi returned in 0.60 seconds, and its shared local container grew by approximately 129 MiB at peak during sampling. That aggregate includes other app activity. The Helumi mount supplied the readback; its cloud publication time and the branch taken by this copy remain unknown. Both generated files were removed after verification. These were individual runs on different providers. [Measured results](evidence/finder-upload-comparison.json)

## From a user gesture to bytes

| Entry | Build-45 evidence | What the caller supplies |
|---|---|---|
| App drop target | Host displays “Drop to add to Helumi”. Function at `0x1000b0ff8` reads `draggingPasteboard`, constructs an NSURL reader with `NSPasteboardURLReadingFileURLsOnlyKey`, then invokes `readObjectsForClasses:options:` at `0x1000b1178`. | Local file URLs. The separate reference to the general pasteboard cannot establish interception of Finder Command-V. |
| Finder extension | OrbitFinder exposes `menuForMenuKind`, selected item URLs, and `AddToOrbit.plan(_:into:fileManager:)`, `copy` and `freeName` symbols. | A distinct add/copy route exists. No traced call connects the pasteboard directly to an upload HTTP request. |
| Mount | OrbitFS implements the FSKit preallocation and write selectors. The former calls `OrbitDrive.preallocate` at `0x10001375c`. The latter routes data and offset to `OrbitDrive.write` at `0x1000a6468`. | Item identity, offset, requested allocation length and subsequent byte writes. This accounts for a copy arriving through normal filesystem IO. |

## When a copy can start transferring

In `OrbitDrive.preallocate`, the block at `0x1000ba084–0x1000ba0d4` gates further direct-transfer processing on an enabled positive threshold, offset zero and positive length. The allocation must either reach the configured threshold or leave less than the configured headroom after subtracting the requested length from an available-space estimate. Further item/state conditions occur before the direct-transfer diagnostic at `0x1000bac34`. Crossing the size threshold establishes eligibility. The estimate's exact filesystem accounting and every additional flag have yet to be traced.

The compiled configuration initializer at `0x10008794c` has these defaults. A mount can supply configuration.

| Configuration | Default value |
|---|---:|
| Direct transfer minimum | 128 MiB |
| Headroom for the alternate memory path | 2 GiB |
| Chunk size | 1 MiB |
| Small file limit | 8 MiB |
| Small upload / big upload / metadata slots | 6 / 4 / 8 |
| Upload delay / idle upload delay | 2 s / 30 s |

The slot counts describe separate scheduling resources. Effective HTTP concurrency, multipart part size and delay from closing a particular file to its remote publication require runtime instrumentation.

The write method computes the end of the incoming byte interval with checked arithmetic, then consults a range classifier at `0x1000a65b0`. One result invokes a helper whose diagnostic says “not a plain copy, uploads after it's closed.” A resize path also calls that helper. Other branches save a stream note, report a memory fallback when disk space runs out, or fail a stalled copy. This supports a write-pattern-dependent choice between streaming and close-triggered upload. The exact admissible sequence of holes, rewrites and resizes needs controlled workloads.

A second live build 32 run returned from Finder in 3.76 s. The first observed write was at 0.78 s, the full allocation at 3.59 s and the R2 object was visible at 13.79 s. Independent download verification finished at 19.72 s. The two live runs differed substantially, so the timing of a single copy does not isolate the cause of the delay.

Build 33 used a 256 KiB negotiated NFS write size. On the mounted R2 drive, Finder returned in 13.93 s and 11.61 s. Independent R2 downloads matched the source in both runs. The second run recorded 519 system-wide writes during the copy. The first observed write arrived at 6.51 s and the entire local file was allocated by 6.76 s. Fewer write requests improved the isolated filesystem benchmark, while delays outside the bulk write interval dominated this live run. A generated Logic-shaped package with three nested files, a spaced filename and an accented filename also round-tripped through Finder and R2.

The compact window now opens directly into Finder with transfer activity available separately. The card accepts ordinary local files on the NFS drive. Use Finder for folders on that drive. The native FSKit backend separately passed the app-card folder collision and metadata tests. Resource forks require a Finder-compressed archive for the app-card route. Low-space external imports still use the source-disk flow in Settings. These paths have different local space and recovery behavior.

### Directory browsing during a copy

The older NFS worker fetched a modification time for each neighboring R2 object while producing a directory listing. A disposable S3 fixture with 96 neighbors and a fixed 50 ms metadata delay reproduced the pause. Finder waited roughly six seconds before its first write when a concurrent client requested directory names. Changing the NFS mount flag alone made little difference.

Worker `.9` returns the existing file IDs and handles while deferring optional expensive attributes until requested. Explicit attribute requests still returned the original remote modification date and correct allocation. With the same Finder operation and concurrent browse, all four copies finished in 0.44–0.46 s and made zero neighbor metadata requests. Finder tags, directory contents and provider payload checks passed. These timings measure the simulator. [Paired benchmark](evidence/finder-directory-browse.json)

On the personal R2 mount, a Finder copy with a concurrent name listing returned in 8.12 s on build 34. On installed build 35 two runs returned in 13.09 s and 3.24 s, with independent full R2 download verification completing at 44.81 s and 37.37 s. All three verified copies were removed. Network and filesystem state varied across runs. The controlled directory regression was fixed, while the live Finder timings still exceed the 0.60 s reference. The measured interval includes Finder metadata operations and local acceptance, before the separate cloud download check.

Build 35's actual **Add Files… → Add to Drive** action copied a generated regular file through the same mounted worker. Mounted bytes and a separate R2 download matched the source before cleanup. A second end-to-end Finder test copied a generated `.logicx` directory with three nested payloads, including accented and spaced filenames, and matched all three R2 downloads. This tested package copying, not playback in Logic Pro. The separately registered, installed FSKit extension mounted a disposable native resource and passed pin/free, atomic save, concurrent moves, open-handle rename/unlink and normal eject. The user's existing R2 data continued using its NFS mount.

The final Swift suite passed 497 tests across the app, FSKit adapter and core targets. The packaged worker separately passed 20 concurrent-move checks and the exclusive-file-create test. These checks complement the signed-host and R2 results above.

## Durability and publication

* `Staging.StreamNote` records size, released bytes, closure and memory state. The extension exposes load, save and release-by-range operations. Recovery diagnostics include interrupted direct transfers being removed and uploads expiring. Successful restoration of arbitrary partial streams requires a kill-and-restart test.
* `OrbitAPI.uploadBlob` takes a blob source, resume key, optional progress and a part-completion callback carrying a byte range. There are pending-upload state, part size/count, completion and forget-upload signals. These support part tracking and cleanup. Retry policy, receipt durability ordering and the exact object-store protocol remain unresolved.
* The remote contract separates `uploadStreamBlob` from `commitStream` (name/parent/client ID) and `commitStreamContents` (existing item ID/base content version/device name). This makes a distinction between byte transfer and publishing content into the user's namespace. Naming an upload complete when the last local write returns would lose that distinction.
* `LockedBlobSource.plainBytesCovered(by:)` and `changedSinceRead` indicate tracked source ranges and mutation checks. They do not establish which source changes are recoverable or how concurrent writers are reconciled.

## Adaptive upload speed

`PoliteUploads` accepts a drive, pacer and host. In its control path `0x1000d9f68` calls `UploadGovernor.adjust(rtt:throughput:at:)`. The caller handles an optional result and converts the new value to an integer. Another branch calls `record(rtt:at:)`. The governor exposes baseline RTT, last cut and current rate; the pacer exposes asynchronous byte admission through `take(_:)`. Upload settings persist pause state and an Mbps limit, and a speed meter distinguishes active sending from idle/limited intervals. The combination supports adaptive pacing as well as a manual ceiling. Probe destination, field response curves, fairness with interactive reads, and the actual speeds on this Mac need a live trace.

## BucketDrive implementation and qualification

1. Instrument local acceptance, first outbound byte, close, durable receipt and namespace publication separately in the native owner. Include byte totals and operation ID. Apply equivalent observation to the legacy backend before comparing Finder timings.
2. Admit early streaming only for a fresh generation with a known initial range. Preserve staged bytes or a proven immutable range receipt until a replay can reconstruct the exact local file. A rewrite, truncate or non-sequential write must invalidate incompatible receipts. A low-disk mode needs an explicit recoverability contract.
3. Keep completed remote parts separate from the published destination. Managed volumes should reuse immutable content and guarded manifest publication. Compatible keys need a safe destination commit and provider-specific qualification. Keep prior content readable through already-open handles.
4. Test Finder paste, drag to the mounted volume, app drop and an editor save separately. For each, exercise 127, 128 and 129 MiB, a small file under disk pressure, then seek, overwrite, truncate, pause, restart mid-part and restart after upload before publication. Use disposable data and independently compare the final cloud digest. Report which cases actually started sending before close.
5. Measure a foreground range read during saturated uploads. Vary latency while holding the bandwidth cap fixed, then vary the manual cap at stable latency. Record baseline RTT, admitted bytes, measured throughput and time to recover. A fixed configurable ceiling alone can only pass the manual-limit case.

Equivalent behavior can be evaluated from these observations without copying private APIs, assuming the same storage backend, or treating the reference defaults as performance targets.
