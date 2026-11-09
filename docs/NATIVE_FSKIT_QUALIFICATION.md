# Native FSKit qualification — 2026-11-05

## Observed result

The provisioned native filesystem mounted on macOS 27.3 arm64 and passed generated-file operations in both managed and compatible modes. These runs used an isolated local `FixtureStorageRemote`; they do not establish live-R2 filesystem behavior or performance at production scale.

Managed run used installed build 22. Compatible run used the same filesystem extension with a separately signed engine containing the directory-marker proof fix; include that engine fix in the next installed package before claiming the installed app has this complete result.

Evidence (private generated data; reports contain no IPC authentication tokens):

- `build/personal-drive-completion/native-fskit-evidence/build22-managed-pass.json`
- `build/personal-drive-completion/native-fskit-evidence/marker-fixed-compatible-finder-pass.json`
- Earlier failure: `build/personal-drive-completion/native-fskit-evidence/build22-compatible-publication-failure.json`

Both passing runs verified mkdir, file creation, 2,097,179-byte write/fsync/read, exact byte comparison, folder rename with stable inode, retained open-handle reads, unlink with subsequent open-handle reads and writes, directory removal, unrelated imported-file reads, background publication drain, normal unmount, and owned engine shutdown. Single observed rename samples were approximately 42 ms managed and 49 ms compatible; these are smoke measurements, not percentile or scale claims.

The compatible run additionally paused for an independent Finder observer. Recorded Finder actions: Go to Folder into the native mount, list `seed.bin`, create a folder, rename it, open it, and return to the parent showing its new name. Finder deletion UI, production Finder extension actions, editor-save compatibility, power loss, and live R2 were not tested by this fixture. The raw report's generic “no Finder UI” limitation predates the checkpoint-specific wording fix; its `finderObservation` field records the precise observed scope.

## Defects found and fixed

1. Socket errors were incorrectly collapsed to ECONNREFUSED. `UnixSocketRPCClient` now preserves the kernel errno. This exposed EPERM from the sandboxed extension.
2. A security-scoped path directory did not grant the extension Unix socket IPC into `/tmp`. `NamespaceResourceLocation` derives the shared container from the signed team’s `.cd` app-group entitlement; host, engine, and extension share that group. Production has no temporary-directory fallback. Explicit local fixtures retain a fallback for unentitled unit/process tests. Socket paths are length bounded.
3. A resident old extension retained its old sandbox after bundle replacement. Refreshing only the verified idle CloudDrive extension loaded the new entitlement; no system filesystem service or user legacy mount was killed for this refresh.
4. Concurrent FSKit page-out callbacks raced staged content generation commits, surfacing ESTALE during fsync. Write and setattr callbacks now hold the per-node handle gate throughout their operation, including all IPC chunks. Close cannot release the shared lease mid-write.
5. Compatible directory markers lack file-content published locators. After rename, a subsequent remove could not resolve the original upload proof to its new key. `SyncEngine.expectedObject` now follows durable verified aliases from prior modified/uploaded receipts, preserving conditional validator checks. A test proves externally replaced markers are not deleted.
6. The qualifier originally compared a `/var` temporary path with mount's canonical `/private/var` path. It now canonicalizes the fixture root before mount creation. One earlier synthetic mount required explicitly authorized force cleanup after this harness defect; neither final passing run required force cleanup.

## Regression checks

- Three resource-location/socket tests: no production fallback, Unix path-length guard, actual ENOENT preservation.
- Five FSKit callback tests, including eight concurrent multi-frame writes against a suspended transaction model.
- Forty-four SyncEngine tests after the directory-marker change, plus a separate external-marker replacement fence regression.
- Actual native managed and compatible mount runs described above.

## Harness

`scripts/qualify-fskit-mounted.py --mount-fixture` defaults to the installed engine. `--mode compatible` selects ordinary-key storage. `--engine` can select a deliberately signed candidate. `--finder-checkpoint` prints a mountpoint and acknowledgement file and waits at most 120 seconds for explicitly observed Finder actions; it does not invent UI verification.

The harness creates private generated state, never loads saved cloud credentials, retains evidence, validates mounted source/type, normally unmounts, and refuses to stop an owner while its mount remains or it is unsafe to stop. Unmount flush failures remain errors rather than false claims of durability. No automatic force-unmount is implemented.
