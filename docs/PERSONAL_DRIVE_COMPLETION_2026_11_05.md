# Personal drive completion — November 5, 2026

Scope: a personal macOS cloud drive. Sharing and file requests are excluded. Source/test improvements, package readiness and actual installed behavior are distinct evidence levels below. Earlier findings remain in the Helumi dossier and implementation progress files.

## Recently Deleted

`NamespaceTrashView.swift` supports explicit selected-item permanent removal with a confirmation listing every selected item. Folder confirmation includes contents. The action binds to the selected destination, disables submission while processing, stops on an unconfirmed failure and never runs automatically. The controller requires the owner's durable `removedFromRecentlyDeleted=true` acknowledgment; a subsequent telemetry refresh failure does not reclassify an accepted destructive operation as unperformed.

“Permanent” means the selected entry cannot be restored through Recently Deleted. Immutable remote recovery history and compatible-mode backup data may remain. This is neither secure erase nor a promise of reclaimed bucket space. Existing open handles remain supported by the core implementation. Core purge/replay/restore safety tests are tracked by the architecture qualification work.

UI/onboarding verification: `/tmp/bucketdrive-trash-ui-tests.log`, 17 tests executed, 16 passed and one environment skip. The skipped keyboard-focus assertion is conditional on the test host reporting `com.apple.loginwindow` frontmost; it is not a passing focus qualification or a claim about the user's visible desktop. No real user files were removed for these UI tests.

## FSKit provisioning

Successful command:

```sh
python3 scripts/provision-fskit.py --team EGEBBVL76D --apply
```

Result: exit 0, `ready-for-packaging`. The extension profile authorizes FSKit, is valid, matches the existing team and includes the pinned app certificate. Strict extension signing checks passed; the pinned signer was retained. No personal certificate subject or account credentials are included here.

Evidence paths relative to the repository:

- `build/fskit-provisioning/provision-23f25d456e804a71b1e1f29749c2aa39.log`
- `build/fskit-provisioning/Products/Debug/CloudDriveFS.appex`
- `build/fskit-provisioning/Products/Debug/CloudDriveFS.appex/Contents/embedded.provisionprofile`

Profile SHA-256: `778266be1c18a133ec26f2e38d6589f190f1aab3def1dca370f47be2c90c5e36`.

See [FSKit setup](FSKIT_SETUP.md) for packaging and activation. An Xcode build requires explicit inclusion flags as command-line build settings because project defaults override shell environment values. Inspect actual embedded extensions; a successful app build alone does not prove inclusion. The direct packaging script supports environment values.

## Onboarding and legacy move guidance

The setup UI distinguishes a missing component from unconfirmed macOS activation and an observed connection. It links to Login Items & Extensions and gives the File System Extensions approval path. FinderSync approval is separate. Merely finding a provisioning profile never changes the UI to “connected.”

Legacy bucket testing is disabled during active moves, pending move recovery or unknown expected move status. Its implementation also checks authenticated worker move state before creating its disposable fixture. The UI explains that Finder browsing may wait while a legacy move completes, and instructs the user to keep CloudDrive running and finish or resume the move. This guard does not classify a busy legacy mount as an R2 failure and does not advise forced disconnect.

## Installed and live qualification

Provisioning evidence above does not establish actual FSKit activation, Finder badges, real R2 verification or installed-app behavior. Those results will be appended with their own evidence by the installation/qualification owner. Existing live user work must remain intact; use isolated synthetic fixtures for qualification.

Legacy move guard regression evidence: both `DriveLifecycleTests.testEjectDetachesActiveMoveWithEmptyUploadQueueAndStopsOnlyAfterIdle` and `testUnfinishedMoveBlocksDirectWriterAndRetainsWorkerOnEject` passed with zero failures after the guard change. They assert testing is blocked without a false failure or receipt and existing workers remain alive. Logs: `/tmp/bucketdrive-move-verification-guard.log` and `/tmp/bucketdrive-recovery-verification-guard.log`. These use isolated test fixtures, not the user's live move.

### Later recovery-hang investigation

A later app sample (`/tmp/clouddrive-hang-sample.txt`, collected by the installation owner) found implicit filesystem inspection while constructing a mount URL. The owner corrected both mountpoint getters to specify directory intent. Follow-up audit corrected FinderSync mount construction, lexical mount-source normalization and Finder confirmation basename extraction to use explicit URL type hints. Storage accounting now excludes both `Drive` and `Instant Drive` before any child stat, avoiding traversal of stale mountpoints. Two `LocalStorageTests` passed (`/tmp/bucketdrive-mount-scan-tests.log`); the fixture verifies both mounted-directory names are excluded. This is not a deliberately hung live mount test. At this later point the previous worker had exited and recovery was being investigated; earlier observed move progress is not evidence that the move remained healthy.

### Finder availability badge consumer

The Finder extension now reads only the computed `com.clouddrive.availability` xattr on the configured native mount. It checks the mount table without waiting, opens metadata-only with no-follow semantics, rejects symlinks and checks the opened descriptor's filesystem and exact mount path. It never reads credentials, owner descriptors or private application state. Unknown values, malformed or oversized payloads, permission errors and unavailable metadata produce no badge. Four recognized values map to Online only, Downloading, Available offline and Needs attention.

Reads are limited to two concurrent workers and 64 outstanding requests. A request expires after five seconds, clearing its badge even if the underlying filesystem call stalls. Superseded replies cannot restore an old badge. A future Finder request can refresh the evidence; this implementation does not promise continuous positive badge display. Sandboxed xattr access and actual mounted Finder rendering still require live qualification.

Standalone parser/freshness/race checks passed with the real consumer source compiled against the current core library:

```sh
xcrun swiftc -module-name FinderBadgeChecks -I .build/out/Products/Debug -L .build/out/Products/Debug -lCloudDriveCore -lsqlite3 -framework FinderSync Sources/CloudDriveFinder/FinderSync.swift Tests/FinderBadgeChecks/main.swift -o /tmp/clouddrive-finder-badge-checks
/tmp/clouddrive-finder-badge-checks
```

These are consumer contract checks, not simulated proof of positive mounted badges. The FSKit producer and owner verification are independently implemented and qualified by the filesystem workstream.

## Installed Mac and live results

On this Mac the personal app was installed in `/Applications/CloudDrive.app`, signed with the original identity, and both extension switches were enabled. The app-level FSKit switch was insufficient; the exact CloudDrive Filesystem entry under By Category → File System Extensions was enabled. Host and engine use only the team-prefixed application group for the private socket; the FSKit module additionally uses its Apple-provisioned entitlements. A profile-free or globally accessible IPC workaround was not used.

The installed signed app exercised generated R2 objects in unique prefixes: conditional create/replace, exact byte-range and list results, conditional copy, and 17 MiB multipart upload with independent full readback passed. The wrong-validator DELETE capability could not be established. Report: `build/personal-drive-completion/live-r2-final.json`. Conditional deletion remains disabled for this provider, and the generated objects are retained; a passed upload does not imply safe ordinary-key rename/delete admission.

Both managed and compatible real FSKit mounts passed the local synthetic scenarios after per-file write serialization and generation-safe marker relocation fixes. On the compatible mount, Finder itself listed the seed file, created a folder, renamed it, opened it and showed the new name after returning to the root. That exact checkpoint and normal unmount/publication result are in `build/personal-drive-completion/native-fskit-evidence/marker-fixed-compatible-finder-pass.json`. See [native verification](NATIVE_FSKIT_QUALIFICATION.md).

A combined suite passed **473 Swift tests** (315 app, 8 adapter, 150 core) with no skips or failures, and **38 Python tests** passed. This run preceded the final signed-peer team-metadata correction and per-item xattr advertisement; additional results are recorded below when available.

### Existing legacy drive

The live legacy NFS drive showed the server interruption alert during an existing 8,700-item move. Authenticated worker state initially reported ongoing copy progress and no upload errors. Later its process exited; no cause was confirmed. The move records and cache were retained. The old app process became stuck exiting and a normal unmount remained in an uninterruptible kernel wait despite disappearing from the mount table. The old process retained the app owner lock. No forced unmount was performed on the user’s drive, and the test fixtures did not migrate or overwrite its namespace. A new app bundle, signing profile, or passing synthetic mount does not release an existing kernel wait.

### Recovering the personal drive after a normal restart

Save open work and restart the Mac normally if the old unmount and owner lock are still present. Open /Applications/CloudDrive.app. Cold launch checks the saved worker identity, destination, mount and cache before retiring a dead session. If they agree and the saved connection loads, it can reconnect the legacy Finder drive. Ordinary queued uploads may resume. The interrupted move requires a separate **Resume move** action on the dashboard or menu bar. Inspect the recovery status before choosing it. If Keychain access prevented automatic connection, use **Manage Drive → Load Saved Connection**, complete the macOS prompt, then **Retry Recovery** and **Connect Finder browsing** if offered. If CloudDrive reports a conflicting identity or mount, preserve its records. This is the recovery behavior in the source; recovery of the user's interrupted move has not been observed.

### Installed availability and full-suite retest

Build 25 passed both mounted availability runs (managed and compatible). Repeated metadata reads reported online-only on a remote file, available-offline after pinning and verifying its bytes, and online-only again after unpinning and freeing the cache. Both fixtures then passed native writes, fsync and SHA-256, folder rename, open-handle and unlink behavior, publication drain, normal unmount and owner stop. Reports: `build/personal-drive-completion/native-fskit-evidence/build25-{managed,compatible}-availability.json`. These are real filesystem attribute reads; the positive Finder icon on the configured personal mount was not visually observed. The combined Swift suite passed again (473 tests) after the signed peer and per-item xattr fixes; log: `build/personal-drive-completion/final-installed-source-tests.log`.

### Final installed build: native FSKit to real R2

Signed build 28 at /Applications/CloudDrive.app passed all eight stages in `build/personal-drive-completion/native-r2-build28-evidence.json`. The test mounted a generated, isolated managed R2 namespace; wrote 2 MiB through FSKit; flushed, read and renamed the file; then replaced a newly created nonempty destination while an open reader retained its old bytes. The owner published all revisions and an independent R2 client read the published object with the expected SHA-256 (`d75b8fd8e318424d0f52f552beaddb1c2353ad0fd869e8b1540ee81cccb7e7c1`). The volume unmounted normally and the authenticated owner stopped. The five native R2 test sessions left no mounted volumes or running owners. Generated remote objects remain under their private test prefixes. General Finder badge rendering, full editor compatibility, sleep/wake and long-duration use were not inferred from these tests.

The app/engine/Finder/FSKit hashes are in `build/personal-drive-completion/installed-final-manifest.json`; signed packaging validation is in `readiness-28.json` alongside the manifest. The regression fixes cover signed caller identity, per-item xattr advertisement, serialized writes, compatible directory-marker relocation and atomic regular-file replacement while publication is pending. No blanket support for the separate Darwin exclusive-rename flag is claimed.

Both installed build 28 fixtures then passed atomic replacement with remote publication deliberately paused, old and new file descriptions isolated, availability pin/free transitions, publication drain, normal unmount and safe owner shutdown. Compatible mode independently verified the ordinary provider key contained the replacement bytes. Evidence: `native-fskit-evidence/build28-managed-replacement.json` and `native-fskit-evidence/build28-compatible-replacement.json` in the same local evidence directory. The final mount table and process checks showed zero test mounts and zero test owners before restart.

### Post-restart result

After the normal Mac restart, installed build 28 reopened at login. Finder browsing was initially off. Choosing **Connect Finder** mounted the saved personal drive, and **Open in Finder** displayed its root with 11 entries, including existing personal folders and the retained qualification prefixes. The dashboard reported **Move needs attention** and offered **Resume move**. That action was left untouched. The personal drive is still on its existing legacy mount; the independently verified native FSKit-to-R2 run used an isolated prefix.

### Full installed feature retest

The post-restart retest passed 475 Swift and 38 Python tests and exercised both native layouts, the legacy Finder path, R2 readback and encrypted recovery. See the [feature report](../build/feature-retest/FEATURE-TEST-REPORT.md) for coverage, retained fixtures, diagnostic timeout correction and remaining limits. The final native R2 run loaded its FSKit module from the installed app, passed independent checksum verification, unmounted normally and stopped its test owner. The personal NFS drive was connected with its interrupted move awaiting resume.
