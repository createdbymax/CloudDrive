# Helumi experience parity: development specification

Date: 2026-11-05. Scope: BucketDrive/CloudDrive desktop interaction, Finder integration, search, transfers and settings. This is a development specification, not an implementation or a claim of exact visual parity.

## Evidence boundary

The installed reference is **Helumi 0.3.18 (45)**, with `LSUIElement=true` and minimum macOS `26.0`, observed in `/Applications/Helumi.app/Contents/Info.plist`. This is newer than 0.3.13 (39) in the earlier file-management plan. Do not attach earlier addresses or timings to this build without revalidation.

Local artifact anchors used here:

| ID | Artifact / method | Observation and limit |
|---|---|---|
| UX-H1 | Main executable `/Applications/Helumi.app/Contents/MacOS/Helumi`; SHA-256 `733c3cc0d52a474800cd00e0d64ca14cc54d3043b7a210ddce545922d3b63054`; `strings` | Embedded type names and UI copy, not proof those views are reachable or active |
| UX-H2 | Finder executable `/Applications/Helumi.app/Contents/PlugIns/OrbitFinder.appex/Contents/MacOS/OrbitFinder`; SHA-256 `49774a0d490d75cd77cd1cd4fd939bf2bd86bf6ea357871ef3ce94daded0b968`; `strings` | Context-action labels, selectors and state names; not a mounted Finder interaction test |
| UX-H3 | Main Info.plist parsed with `plutil -p` | Version, menu-bar-style agent declaration, website/API configuration, automatic-update declarations; no service request made |
| UX-B1 | Current working tree, based on Git HEAD `51701897ed343412ee19f8dbdaf44382b6b44eae` plus existing modifications | Source inspection only; uncommitted implementation is substantial. Source presence is not shipping or runtime qualification |

Runtime evidence supplied by the lead investigator is retained in the local UI notes (UX-R1). It covers the idle main window and General, Storage and Encryption settings. Account and real file operations were not exercised. No settings were changed and no recovery secret was read.

These local IDs complement the REA evidence ledger in this dossier; they are not REA-issued Evidence IDs. Strings can include dead code, frameworks and partial compiler literals. Product-specific copy below is bounded to the main and Finder executables, excluding generic Sentry networking messages. Exact layout, spacing, material, motion curves, focus behavior and performance require the runtime observations and comparison protocol below.

### Observed runtime visual baseline (UX-R1)

The inspected main window is compact and dark, containing one rounded card with logo/title, green check, **Up to date**, supporting text **Your files are safe in the cloud.**, and an **Open in Finder** pill on the right. This is substantially quieter than our default 900×700 dashboard; retain the full dashboard as an explicit management surface and add a compact drive-status window if matching this daily interaction is the objective.

Settings use a native toolbar with **General, Storage, Encryption, Account**. General includes launch at login, upload speed (As fast as possible, 50/20/10/5 Mbps), global search shortcut **Control–Option–O**, automatic updates/version check and error-report control. Storage offers **Automatic, 5/10/25/50/100 GB**, reports usage and has **Remove Recent Files**. Supporting copy describes recently used file parts and reclaiming space under disk pressure. Encryption visibly reports encryption on, all files encrypted, metadata sizes/dates visible, recovery key saved and a Make a New Key action. These are observed UI statements, not independent verification of cryptographic design or safety.

Exact pixel sizes, animation curves and keyboard behavior remain unmeasured. Do not describe our proposed geometry below as a recovered Helumi specification.

## 1. Experience intent and decisions

The reference suggests a Finder-first product: a background app with onboarding, a compact status surface, fast global search, ordinary file actions, and recovery language that explains what happened to the user's files. Our equivalent should feel dependable before it feels animated.

1. Preserve the direct R2 model. Helumi's browser sign-in, subscription/account website and service-backed sharing are different product capabilities, not merely alternate labels for our credentials screen.
2. Keep one foreground action per state: finish setup, open Finder, resume, or resolve an issue. Diagnostics are available from details.
3. Decide explicitly whether exact shortcut parity is desired: Helumi displays Control–Option–O; our existing Option–Space is a different behavior. A configurable shortcut preserves user choice and lets a parity preset match the reference.
4. Treat Finder attachment, local durability, remote publication, cached availability and account authorization as independent state dimensions.
5. Never animate progress past confirmed work. “Saved on this Mac” and “Uploaded” must remain distinguishable.
6. Preserve accessible native controls and system appearance. Reproduce observable interaction outcomes with our own assets and components.

## 2. Capability map

| Surface | Helumi evidence | BucketDrive source today | Development delta |
|---|---|---|---|
| Background presence | UX-H3 agent declaration; UX-H1 `EjectWatcher` | `App.swift`: menu extra, dashboard/settings/search/recovery windows, persists after last window closes | Keep application lifetime separate from window lifetime; qualify menu-only operation |
| Setup | UX-H1 browser sign-in, “Two quick switches in System Settings”, automatic continuation copy | `ConnectionViews.swift`: R2 fields, save/connect, load saved connection | Staged setup with independently checked prerequisites and resumable progress |
| Menu and status | UX-H1 upload/paused/offline/ejected states | `DriveMenu.swift`, `StatusPresentation.swift` | One presentation model across legacy/direct/namespace modes; reconcile stale status and recovery |
| Transfers | UX-H1 `UploadCard`, `WebUploadCard`, `UploadBatch`, stopped/gentle uploads | `DirectUploadCard.swift`, `TransfersView.swift`, `NamespaceTransfersView.swift` | Consistent rows and actions across origins; namespace view currently aggregates counts rather than full queue |
| Search | UX-H1 `SearchPanel`, `SearchView`, `SearchKind`, “Search from anywhere” | `SpotlightPanelController.swift`, `SpotlightSearchView.swift`, `SearchView.swift` | Keep established launcher; verify reference filters, result ranking, actions and keyboard behavior |
| Offline files | UX-H2 “Keep on This Mac”, `toggleKeep:`, `keepWaitingForSpace` | `NamespaceFileActions.swift`: keep downloaded/free local space; namespace counters | Per-item pin state, progress, failure and Finder entry points; correct settings copy |
| Sharing / requests | UX-H2 “Copy Share Links”, “Request Files”; selectors | No matching product surface established by inspected UI files | Separate service/transport workstream; do not show active commands before backend and policy exist |
| Deleted files | UX-H1 website copy mentions Recently Deleted; `TrashItem` type | `ConnectionViews.swift` explicitly says restoration unavailable | Define retention/restore backend, then surface recovery; not equivalent to upload cancellation |
| Encryption | UX-R1 Encryption tab claims encrypted files and recovery-key management | No encryption capability established in the inspected UI; existing settings say unavailable | Separate data-format, key lifecycle and recovery project; UI alone cannot deliver parity |
| Settings | UX-H1 `AccountSettings`, `PrivacySettings`, `StorageSettings`, `GeneralSettings`, `UpdateSettings` | `DriveSettingsView.swift`: General, Transfers, Storage, File management, Connection, Diagnostics | Capability-aware organization; launch, search shortcut, storage, update and privacy controls |

## 3. Shared presentation contract (P0)

Introduce a presentation projection beside `StatusPresentation`, backed by authoritative owner snapshots. Do not let each view infer “done” from a separate counter. Suggested fields:

- `attachment`: detached / connecting / attached / ejecting / blocked.
- `localSave`: none / saving / durable / failed.
- `cloud`: idle / queued / transferring / verifying / retrying / paused / offline / attention / unknown.
- `availability`: remoteOnly / partlyCached / downloaded / pinPending / pinFailed.
- `sampledAt`, `sourceGeneration`, `destinationID`, `localRevision`, `publishedRevision`.
- `primaryAction`, `secondaryActions`, `userMessage`, optional expanded diagnostic context.

Source integration: `StatusPresentation.swift`, `NamespaceTransferPresentation` in `NamespaceTransfersView.swift`, `DirectUploadRowPresentation` in `DirectUploadCard.swift`, and `DriveMenu.swift`. Keep present safeguards such as the five-second `UploadFreshness` boundary until an equivalent snapshot freshness policy replaces them.

| Situation | Primary label | Primary action | Invariant |
|---|---|---|---|
| Connected, no pending work, fresh confirmed state | Up to date | Open in Finder | Only use after publication confirmation |
| Local edit acknowledged, cloud pending | Saved on this Mac · Uploading | View activity | Local save is not cloud completion |
| Offline with durable edits | Offline · Changes saved on this Mac | View activity | Never claim safety if local save failed |
| User paused | Uploads paused | Resume | Paused is intentional, not an error |
| Missing telemetry | Status unavailable | Retry status | Keep pending data protected |
| Storage pressure | More space needed | Review local storage | Do not suggest deleting pending cache |
| Detached, owner still syncing | Finder ejected · Uploading | View activity | Detachment is not cancellation |
| Busy file prevents eject | Close open files to eject | Try again | No force-unmount default |
| Pin requested but incomplete | Downloading for offline use | View progress | Do not show “Available offline” yet |

Potential current inconsistency: `NamespaceTransfersView` displays “Cloud copy: Confirmed in R2” whenever revisions match, even when other fields indicate attention or work. Derive that row from the same validated completion predicate as its title. `DriveSettingsView.general` says offline pins are unavailable even though namespace actions exist; make capability messaging mode-specific after qualification.

Acceptance: snapshot table tests cover every row, stale sample, negative counters, generation changes, reordering, owner restart, detached progress and equal revisions with dirty bytes. Dashboard, menu and activity detail show equivalent truth for the same fixture.

## 4. Setup and authorization (P0/P1)

Proposed sequence for our product:

1. **Connect storage**: brief ownership explanation, endpoint/bucket/prefix, secure credentials. Preserve current Keychain behavior. Show field-specific validation without replacing typed values.
2. **Choose file-management mode**: make compatibility consequences understandable. Existing ordinary-key buckets remain explicit; managed layout is a separate informed choice. Do not bury a storage-format change in “Continue”.
3. **Enable Finder integration**: detect relevant extension/helper status; show one action for the missing prerequisite. Only show System Settings directions applicable to the selected adapter/OS.
4. **Prepare drive**: finite phases such as validating connection, reading metadata and attaching Finder. Indeterminate phases use an indeterminate indicator, not fabricated percentages.
5. **Ready**: Open in Finder; secondary “Search your drive”. No requirement to visit diagnostics.

UX-H1 contains “Two quick switches in System Settings. Helumi waits and continues on its own.” Reproduce the outcome with explicit status detection and automatic continuation after permission changes. This does not prove Helumi's exact detection APIs or timing.

Persist setup progress excluding secrets. A denied permission leaves a usable retry path. Relaunch resumes the last safe phase; changing destination invalidates stale preparation results. Keychain dialogs remain triggered by the user's explicit load/connect action, following existing `RecoveryActions` semantics.

Acceptance: fresh install, denied authorization, return from System Settings, relaunch mid-setup, offline validation, invalid endpoint, missing bucket, saved key locked, wrong destination and successful repeat connection. No secret values in validation output or logs.

## 5. Menu bar and drive surface (P1)

Retain `DriveMenu` as the lightweight entry point. Proposed order: concise status, Open in Finder/Connect, Search, Activity, context-sensitive Pause/Resume, Settings, Eject, Quit. If an operation needs attention, show a single actionable entry that opens the affected detail. Avoid multiple separate recovery labels for the same condition.

The existing dashboard is useful for explicit operations, but its navigation should not be required for normal file access. Keep drive identity, current state and one primary action visible; place cache metrics and backend details behind disclosure or settings. Upload-origin segmentation may remain as an advanced filter while legacy and native paths are mutually exclusive.

Do not remove current switching guards merely to simplify copy. `StatusPresentation` explicitly reports that direct uploads disable Finder browsing. Until shared ownership supports concurrent paths, explain the switch once when initiating it; do not repeatedly restate internals on every idle card.

Acceptance: menu reflects current state without reopening, keyboard menu operation works, window closing leaves transfers alive, reopening preserves filter/selection, and app termination uses existing worker/data safeguards. Complete the same tests after changing appearance and display scale.

## 6. Unified activity and transfer behavior (P0/P1)

Current foundations: `DirectUploadSlots.select` stabilizes visible slots; `DirectUploadCard` separates verified progress from animation, paginates long lists, supports accessible native drop handling; `NamespaceTransfersView` currently gives summary metrics and pause/resume.

Add a shared `ActivityItem` projection keyed by durable operation ID and origin. Required fields: file identity, display name/parent, kind, phase, confirmed bytes/total, queued time, retry time, error category, allowed actions and durability location. Origins can include Finder, direct upload, metadata operation, offline download and restoration. A multi-file drag is a batch with expandable children, not a replacement for per-file outcomes.

Rows: icon; filename; short secondary phase; progress when meaningful; one primary contextual action; details menu. Use stable ordering while active. Completion stays visible briefly and remains in history. An empty queue means no queued work; it must not erase unresolved records.

States: preparing → queued → uploading → verifying → completed; branches to pausing/paused, retrying, source unavailable, destination mismatch, stopped or attention. Namespace metadata operations can skip byte progress. Unknown totals do not show 0% indefinitely.

### Pause versus stop

UX-H1 includes stopped-upload recovery to Downloads and restoration of stopped uploads. This supports a recovery-oriented reference design, not a proven transaction protocol.

- **Pause** retains the job, durable staging or source reference, and confirmed receipts.
- **Stop** ends future work. Direct uploads retain the original external file; do not copy it unnecessarily. Finder-created data may have no other durable copy and requires a verified recoverable destination before staging can be removed.
- **Remove from history** affects history only and is never the stop action.
- A recovery export must handle name collisions, insufficient space, permission failures and restart mid-copy. Show the actual destination and provide Reveal in Finder.
- Restoring a stopped file creates a new explicit operation linked to the old record. Never assume its former cloud path is still free.

### Gentle uploads

UX-R1 confirms a fixed speed menu in the observed General screen; it does not demonstrate adaptive bandwidth behavior. UX-H1 explicitly describes limiting uploads to keep calls/browsing smooth and says opening files is not slowed. Current `DriveSettingsView` exposes a fixed upload limit and parallel file count. Proposed parity work: optional adaptive upload policy with separate foreground-read priority; preserve a manual ceiling and show applied policy readback. Do not claim adaptive behavior from a static rate cap. Measure read latency under upload saturation before calling the feature complete.

Acceptance: 1/100/10,000-file batches, long names, zero-byte files, retries, disconnection, changed originals, detached source volume, stop with sole-copy data, stop with existing original, pause/relaunch/resume, incorrect destination, completion verification failure, and stale progress. Neither layout nor text should reorder beneath a focused action during updates.

## 7. Search launcher (P1)

Existing implementation already provides Option–Space via Carbon, menu fallback on conflict, a nonactivating panel, active-screen positioning, Escape/outside-click dismissal, six visible results, arrow selection, Return open and Command–Return reveal. Preserve these behaviors in `SpotlightPanelController` and `SpotlightSearchView`; replacing the launcher wholesale is unnecessary.

Required improvements:

- Include node identity and current parent display after local moves. Do not wait for remote publication to update search.
- Describe index coverage and freshness separately from no matches. Offline name search may succeed while opening remote-only contents cannot.
- Show availability badges and contextual offline actions. Hide unsupported actions by capability, not generic drive-connected status.
- Add explicit search-scope/type controls only after inspecting reference behavior or establishing product need; `SearchKind` alone does not prove exact filter semantics.
- Maintain cancellation and query-generation checks so late results cannot replace newer text.
- Keep selected item identity stable when background indexing updates results; if removed, select the nearest surviving row and announce it.

Acceptance: shortcut conflict, multiple screens, full-screen app, different Spaces, rapid input/delete, IME composition, non-Latin names, no matches, incomplete index, offline remote-only result, moved item, deleted item, permission failure, and returning focus after open or dismissal. Log search latency on a declared dataset; proposed warm-query p95 budget is 100 ms, not a measurement of Helumi.

## 8. Finder commands, offline state and badges (P1/P2)

UX-H2 contains `copyShareLink:`, `requestFiles:`, `toggleKeep:`, “Keep on This Mac”, “Copy Share Links” and “Request Files”. This establishes shipped command candidates. Finder badges and selection-dependent menus still need observation.

For our first parity increment: add a Finder extension that forwards selected stable identities to the same namespace owner used by `NamespaceFileActions`. Support Keep downloaded, Free local space and Show activity. Cache/pin mutations must not be duplicated in the extension.

Proposed badges: cloud-only, downloading, available offline, pending upload, attention. Distinguish pin intent from verified offline completeness. A fully cached unpinned file may be evicted; its badge must not promise permanence. Multi-selection commands return per-item outcomes and handle mixed state without claiming all succeeded.

Free local space only removes releasable clean bytes; pending writes, active handles and protected pin roots remain governed by the engine. Explain remaining retained data instead of presenting a misleading successful zero-byte cleanup.

Acceptance: nested pin roots, rename while pinned, partially downloaded directory, disk pressure, rejected pin, Finder relaunch, extension disabled, owner unavailable, mixed selections, stale URLs and multiple drives.

## 9. Sharing, file requests and Recently Deleted (separate P2 product capability)

These are material parity gaps, not decorative UI additions. UX-H1 explicitly places sharing and Recently Deleted on the Helumi website; UX-H2 exposes Finder commands. Static strings do not establish encryption, recipient authorization, expiry policy, upload limits or deletion retention.

Before implementation, specify the original backend contract: link creation/revocation, selected version versus live file behavior, expiration, request destination and limits, recipient upload validation, conflict handling, audit records, retention and restore. Direct S3 credentials must never appear in public links. A signed temporary object URL is not automatically equivalent to a managed share or file-request inbox.

Desktop requirements after backend readiness: create/copy link with explicit pending and failure state; copy only after confirmed success; show links pending upload; revoke from management view; create folder-scoped requests; route Recently Deleted to a working restore surface. Keep unsupported commands absent until they can fulfil their promise.

Acceptance: share before upload finishes, changed/deleted file, revoked/expired link, offline request, mixed multi-selection, request quota exhaustion, malicious filename, restore collision, restore without source content, and account/connection changes. Share/private-service behavior remains unresolved until a separately authorized test environment exists.

### Encryption parity is a separate major workstream

The observed Encryption settings add a substantial gap beyond sharing. Matching this function would require an explicit encrypted storage format, authenticated content encryption, key derivation/storage, key rotation, device enrolment, recovery export/verification, handling of unuploaded edits, migration/export tooling and a documented metadata-leakage model. Those are proposed engineering requirements, not recovered Helumi algorithms. The reference UI explicitly says sizes/dates remain visible; do not infer which filenames or other metadata are encrypted without additional evidence.

Expose encryption as enabled only after the actual write/read path and recovery process are independently qualified. A “recovery key saved” check must represent a defined verification event; key rotation must not strand existing content or pending uploads. Evaluate the effect on ordinary-object interoperability and sharing before adding a toggle. Preserve the current direct-R2 unencrypted mode until a separately designed migration is approved; do not silently convert existing data. Encrypted multi-device parity is not part of a cosmetic settings change.

Acceptance: wrong key, lost-device recovery, interrupted migration, rotation during uploads, old/new content version reads, corrupted ciphertext, metadata tampering, storage exhaustion, recovery export cancellation and recoverability after total local-state loss. Cryptographic implementation and threat-model review require their own workstream.

## 10. Settings and copy cleanup (P1)

Reference tabs observed in UX-R1 are General, Storage, Encryption and Account. For the current direct-R2 product, proposed top-level settings are General, Transfers, Storage, Connection and Advanced; this intentionally differs until equivalent account/encryption capabilities exist. Place experimental file-management/migration controls under Advanced until release-qualified. General owns launch at login, search shortcut, version/update controls; storage owns cache and offline data; connection owns credentials/destination. Retain diagnostics without exposing backend jargon in everyday status.

Use capability-aware copy. Specifically reconcile `DriveSettingsView.general` (“offline pins … not available yet”) with namespace pin actions, and `ConnectionViews.SetupView` (“Files stay ordinary objects”) with any managed-mode selection. Do not imply all modes use loopback NFS in diagnostics when the FSKit adapter is selected.

Storage breakdown: pending local data; recent-read cache; kept downloaded; metadata; free disk. Use lower-bound or unavailable labels for partial scans. Cache target is a target for reclaimable data, not a guarantee that total app allocation never exceeds it.

Privacy settings require inventorying actual telemetry; Helumi's bundled Sentry framework does not justify introducing telemetry into BucketDrive. Updates must respect existing `UpdateController(canInstall:)` safety and test relaunch with accepted local work.

## 11. Visual, motion and accessibility contract

The qualitative idle/settings baseline above is observed; the following numerical values are **proposed BucketDrive tokens**, not measured Helumi values:

| Element | Initial implementation target | Verification |
|---|---|---|
| Typography | System fonts; title 20–22 pt; primary row 13–14 pt; secondary 11–12 pt | Long labels, text-size preferences and localization remain legible |
| Spacing | 8 pt base, 16–24 pt grouped padding | Repeated controls align without clipping |
| Materials | Native materials with opaque reduced-transparency fallback | Light/dark, Increase Contrast, external monitor |
| Corners | Match existing 24 pt search/upload cards where appropriate | Avoid arbitrary mismatch between adjacent components |
| Motion | 120–180 ms hover/opacity; stable progress; restrained panel transition | No latency introduced before focus/actions work |
| Reduced Motion | Remove spatial movement and matched-geometry transitions | Information and selection unchanged |
| Progress | Native progress tied to confirmed samples | No interpolation mistaken for confirmation |

Existing evidence in our source: `SpotlightSearchView` uses a 0.42-second zero-bounce spring and 0.12-second reduced-motion fade; `DirectUploadCard` uses 0.12/0.16-second hover/drop changes and disables transaction animation for progress. These are current implementation choices, not reference measurements. Tune only against captures and usability checks.

Every icon-only action needs a label; state must not rely on color. VoiceOver order follows visual hierarchy. Progress announcements should be rate-limited and phase changes announced once. Keyboard focus remains on a stable ID through transfer updates. All dismissals are reachable with Escape, all destructive choices explain the file outcome, and all drop surfaces have keyboard file-picker equivalents.

## 12. Development slices and release evidence

| Slice | Owner files/modules | Dependency | Done when |
|---|---|---|---|
| UX-01 truthful shared state | StatusPresentation, NamespaceTransfersView, DriveMenu | Fresh owner snapshots | Shared fixture matrix passes across surfaces |
| UX-02 resumable setup | ConnectionViews, Drive lifecycle, extension status | Qualified adapter/permission detection | Setup fault matrix passes with no duplicate jobs |
| UX-03 unified activity | DirectUploadCard, TransfersView, namespace activity API | Stable durable operation IDs | All origins have accurate rows and contextual actions |
| UX-04 stopped-file recovery | Activity actions, engine export/recovery | Durable sole-copy preservation | Restart during every export phase preserves bytes |
| UX-05 search/availability polish | Spotlight views/model, catalog projection | Stable namespace IDs | Offline/move/selection/keyboard matrix passes |
| UX-06 Finder controls | New Finder extension, owner IPC | Signing and namespace adapter | Real Finder selection/badges/actions qualified |
| UX-07 settings consistency | DriveSettingsView, setup copy | Capability registry | No mode-inaccurate claims in shipped UI |
| UX-08 service parity | Share/request/restore backend and desktop surfaces | Product/backend contracts | End-to-end service fixture suite passes |
| UX-ENC encrypted storage/recovery | Storage transport, key lifecycle, migration and Encryption settings | Explicit encrypted-format design and independent review | Restore/migration/key-lifecycle fault suite passes |
| UX-09 visual comparison | UI fixtures and capture harness | Reachable reference screens | Side-by-side evidence reviewed for each state |

### Comparison protocol for “same functions and feelings”

For each scenario record reference build/digest, our build/digest, macOS, appearance, display scale, input method, fixture sizes and network condition. Capture the initial state, action, immediate response, completion, failure and recovery. Measure input-to-first-feedback separately from durable local completion and remote completion. Keep raw recordings and an annotated result sheet.

Required scenarios: fresh setup; menu idle/uploading/attention; open Finder; rename/move; copy files; open remote file; offline open; pause/resume/stop; eject during work; relaunch during work; global search; pin/free-space; settings; sharing/request/restore if a test service is available. Never use production user files as disposable parity fixtures.

For visual comparison annotate actual geometry, truncation, focus ring, hover state, menu order, transition duration and accessibility output. Exact parity remains **unresolved** for any inaccessible or unobserved screen. A screenshot alone does not establish its action semantics, and a static symbol alone does not establish its appearance.
