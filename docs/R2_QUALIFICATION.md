# Isolated native R2 qualification

`R2QualificationView` runs the app's native S3 transport against a new generated subprefix of the selected connection. It receives a `Connection` from the app; it does not load or export Keychain entries itself.

The destination is `<connection prefix>/clouddrive-qualification-<UUID>`. The run never lists or mutates the parent prefix. Local checkpoints are written privately under `<app root>/Qualifications/<UUID>/report.json`, with transport receipts in the same private run directory. The report contains fixed diagnostic codes, generated relative filenames, hashes and timestamps; it omits endpoint, bucket, account and credentials.

The action transfers roughly 20 MB of generated payload plus readback and copy requests. It performs real provider operations only after the app's explicit Run Test action. Existing files are not fixtures.

## Checks

1. Conditional small PUT with absent destination; duplicate absent and wrong-match attempts must fail without changing the object; correct-match replacement must succeed.
2. Full small-object range readback with an independently generated SHA-256 expectation, followed by scoped list verification.
3. Conditional copy and full byte verification. Explicitly unsupported copy marks the run incomplete while remaining diagnostic checks continue.
4. Native positive/negative conditional DELETE capability test, entirely inside the generated subprefix.
5. A 17 MiB multipart upload using repeatable readers of at most 16 MiB, followed by complete 1 MiB ranged readback and SHA-256 comparison.
6. Cleanup only after all required checks pass. Every tracked receipt is checked before deletion begins; each DELETE uses its exact validator and is followed by a missing-object check. The multipart staging object is tracked only when its expected operation identity and size match.

Failure, cancellation and unknown outcomes do not trigger prefix-wide cleanup. The generated fixture is retained for inspection; it may contain additional objects from operations whose responses were lost. A cleanup failure can leave a partially cleaned fixture, recorded by remaining receipts. No unconditional deletion or guessed-object cleanup is performed.

## Results and boundaries

A passing report covers the named operations on the selected provider during that run. It does not qualify large ordinary-key copies, crash/power-loss recovery, external writers, all object layouts, or mounted Finder behavior. A failed or incomplete report must not be presented as general R2 incompatibility without inspecting its fixed diagnostic code and operation.

Five offline scenario tests cover complete verification/cleanup, corrupted byte refusal, unsupported copy preservation, changed-generation cleanup refusal, deterministic ranged payloads and allocation bounds. They perform no live requests. Live results must be recorded separately from these tests.

An unsupported conditional-delete probe, like an unsupported copy, marks the run incomplete but permits independent multipart/readback diagnostics. Cleanup is skipped for every incomplete run.

A DEBUG build also provides an explicitly opted-in diagnostic entry:
`CloudDrive.app/Contents/MacOS/CloudDrive --qualify-r2`.
It starts only the AppKit event loop and diagnostic delegate, with prohibited
activation; it never constructs SwiftUI scenes, starts updates/shortcuts/catalog
watchers, or runs drive recovery. Its inert Drive has Keychain use and automatic
recovery disabled. The diagnostic itself loads the saved connection once with
`Credentials.loadBounded(allowInteraction: false)`; it cannot prompt or change
credentials. Only fixed status and the local report path are emitted as JSON.
Exit codes: 0 passed, 2 incomplete (fixtures retained), 1 failure, 3 saved
connection unavailable, 64 extra/invalid arguments. Release builds never opt
into this entry. Run only when explicitly authorized to perform live provider
qualification. Existing owner locks and drive data are not touched.

The DEBUG `--qualify-native-r2` entry adds actual FSKit POSIX operations to live
R2 qualification. It requires a correctly installed, approved module and signed
host/engine group membership. It creates a fresh `Qualifications/native-UUID`
private directory and a `clouddrive-native-qualification-UUID` remote subprefix,
checks that prefix is empty, and starts its own signed managed owner with
credentials only on stdin. After managed bootstrap it enables writes, mounts a
separate synthetic mountpoint, and verifies the exact native source and mount ID.
A signed child process creates an exclusive 2 MiB deterministic file, fsyncs it,
checks readback, checks that the destination is absent, renames it with ordinary POSIX rename, and checks readback again. It then creates an exclusive nonempty destination, immediately replaces it while its descriptor remains open, verifies the earlier bytes through that descriptor and checks the surviving path contains the full 2 MiB payload. The parent
waits for publication to drain and verifies the published backing object's bytes
and SHA256 independently through S3. Successful cleanup uses only normal unmount
and a detached, quiescent prepareStop before signalling the process it created.
Remote objects and local evidence remain intentionally retained.

Every failure retains owner/mount/state; there is no forced unmount, existing
session recovery, or deletion of remote data. Reports contain fixed stages and
diagnostic codes, hashes, owned PID and synthetic mount/resource paths. No
credentials, account, endpoint or original remote prefix is reported. Mount,
exercise and unmount subprocess deadlines are 25, 40 and 15 seconds; an
independent 240-second watchdog exits only the diagnostic process and leaves the
last checkpoint plus any owner/mount in place. The private exercise entry accepts
only stdin synthetic mount coordinates and checks mount identity before writing.
This proves a native filesystem/R2 path, not a Finder UI interaction or general
release qualification.

To quiesce a retained DEBUG native test owner after normal unmount, run the signed app binary with `--quiesce-native-qualification <run-UUID>`. The command checks the private run directory, exact absent mountpoint, group resource, descriptor session and synthetic binding before authenticating and requesting detach and prepareStop. A successful reply means the owner is safe to stop. Verify its recorded PID, executable, open state database and socket before signalling it. The command performs no provider mutations.

The publication check allows 45 seconds without progress and 150 seconds total.
A decrease in the lowest pending count or an increase in the published revision
extends the idle deadline. Retries, repeated counts, and new local activity do
not extend the total budget. The deadline cancels in-flight status/sync RPCs.
The independent 240-second process watchdog still covers the whole test.

If a prior run timed out at managed publication, normally unmount the exact
synthetic mount and use the signed quiesce command. While its quiescent owner
is still running, the DEBUG app can run
`--verify-native-qualification <run-UUID>` to verify that original run.
It checks the retained owner, zero pending operations, equal published/local
revision and the SHA-256 of the existing immutable backing object. A separate
local readback report records the result. The command reuses the installed
run's generated prefix and issues only read requests to R2.
