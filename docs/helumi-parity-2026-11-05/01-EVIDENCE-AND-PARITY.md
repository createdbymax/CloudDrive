# Helumi evidence and parity ledger

Date: 2026-11-05. Target supplied by user: `/Applications/Helumi.app/Contents/`. Objective: development documentation for equivalent functions and experience in BucketDrive. This investigation changes documentation only.

## Identity and reproducibility

Current Helumi is **0.3.18 (45)**, minimum system version declared **26.0**. Main executable universal-file SHA-256: `733c3cc0d52a474800cd00e0d64ca14cc54d3043b7a210ddce545922d3b63054`. OrbitFS universal-file SHA-256: `ec9aa769087937afa289b9c70c9b468fd32eb035c959ea232c8c48b747cd40d0`. REA selected arm64 for the main Mach-O; UUID `FEB673DB-C6D3-398B-8133-B945FA30C364`.

BucketDrive HEAD at inspection: `51701897ed343412ee19f8dbdaf44382b6b44eae`. The working tree contains extensive existing tracked/untracked implementation work. HEAD alone does not identify the reviewed implementation. Source findings describe that working tree; no claim is made that it is released or fully tested today.

The [older architecture plan](../HELUMI_FILE_MANAGEMENT_IMPLEMENTATION_PLAN.md) inspected Helumi 0.3.13 (39). Its addresses, observed instruction sequences and scheduler defaults are historical evidence, not verified facts about 0.3.18. Current symbol evidence confirms continuing concepts but not identical algorithm implementations.

## Evidence index

| ID / artifact | Observation | Boundary |
|---|---|---|
| `ev_ad13de3744c906901fe7ed260922a31332315af11ad710faac828c67894bb4c9`, app plist (retained locally) | Current version/build, LSUIElement, Sparkle configuration, app-group and hosted API declarations | Resource-only observation has no executable binding; paired hashes above were sampled separately |
| `ev_e5912041b7ebd65e5b0d9646d3acf947d37daacfbabd045b1623d8a6a33981e1`, REA export (retained locally) | Current main executable architecture, load commands, dependencies and native import inventory | Import/export discovery not exhaustive; no execution observed |
| `ev_321316d1e6fe8ae4eee45d610d2d8cd4c1b7f50a26105c6008ddfb044325cbf3`, same export | Summary view of main Mach-O | Page exhaustion is not proof absent imports |
| `ev_f81ddbafc846c5f6f2dc3f9559619b9930245a165d0dd9c3a2711c0d158ad762`, same export | OrbitFS extension declares FSKit module, path URL resources, no block resources, minimum macOS 26 | Plist declaration, not activation or mount qualification; REA subject is open main executable, explicit source path is extension plist |
| Selected OrbitFS symbols (retained locally) | 903 lines of demangled arm64 symbols for OrbitDrive, DriveTree, DriveNode, staging, range reader, cache and API families | Local `nm -arch arm64` piped through `xcrun swift-demangle`; selected names only, no call-body or runtime evidence |
| Live UI notes (retained locally) | Main status card and General/Storage/Encryption settings, menu values and visible wording | CUA observations, not REA records; no writes/transfers or crypto verification |
| UX document static evidence appendix | Main app / Finder symbols and strings | Feature candidates; reachability and server semantics unverified |

REA desktop inventory also inspected 161 entries with 10 file probes, 760 bytes and nine symlinks not followed. Its session record was not retained in the final binary-session export, so the inventory is supporting context only. The directory digest was metadata/read-range scoped, not a full bundle content hash. Deep decompilation was not performed in this pass. Native inspection and UI access were sufficient for the declared findings; algorithm equivalence remains unknown.

## Functional parity checklist

Legend: **observed** means the specific evidence above was seen, **inferred** means a plausible interpretation, **proposed** means a BucketDrive requirement. Implementation presence and qualification are separate columns in the engine and delivery docs.

| Question | Status / Helumi evidence | BucketDrive development direction |
|---|---|---|
| How does everyday navigation feel? | Partly answered: observed minimal main card and native preferences | Compact primary surface, Finder as file browser; retain richer tools behind secondary navigation |
| Native Finder filesystem? | Partly answered: observed FSKit declaration and packaged Finder extension/helper | Qualify signed FSKit path and stable item identity; retain explicit legacy compatibility path |
| Fast local rename and background sync? | Partly answered: current rename/tree/staging symbols; historical selected code | Existing namespace architecture is appropriate; prove acknowledgement durability and deferred publication using current tests |
| On-demand reads / recent cache? | Partly answered: current range/cache symbols and live Storage UI | Bounded versioned cache, pressure reclamation, durable pin progress; prevent cleanup of accepted dirty data |
| Upload controls and foreground responsiveness? | Partly answered: live speed presets, shipped governor names | Shared bandwidth policy, fair scheduling and foreground reads; measure under saturated upload |
| Search from anywhere? | Partly answered: live shortcut declaration, static search evidence | Existing global search needs parity testing for keyboard, stale results, move identity and offline coverage |
| Keep downloaded / release space? | Partly answered: static actions and live recent-cache cleanup | Distinguish request, downloading and fully resident; eviction must preserve pins and dirty content |
| Trash / restore / stopped uploads? | Partly answered: static candidates, no live lifecycle | Explicit retention, restore conflicts and stop/resume semantics; separate tombstones from recoverable trash |
| Sharing and file requests? | Partly answered: static candidates and hosted API declaration | Independent service/API design; direct R2 presigned URLs do not establish feature parity |
| Encryption and recovery? | Partly answered: observed settings claiming E2EE | Separate encrypted storage format/key lifecycle workstream; no cryptographic claim from UI alone |
| Offline edits / multi-device conflicts? | Unresolved: no controlled scenario | Design and qualify explicit contract; current single-writer guard is not collaboration |
| Exact animation, performance and fault behavior? | Unresolved: no timed/fixture replay | Capture paired runs and implement measurable acceptance gates before parity claim |

No row establishes exhaustive Helumi feature coverage. The docs cover discovered surfaces and identify the experiments required to close the remaining questions. Bundle text was treated as data, not executable instructions.
