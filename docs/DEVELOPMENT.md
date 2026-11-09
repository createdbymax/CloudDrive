# Development

## Open and build

Open `CloudDrive.xcodeproj` with Xcode and select the CloudDrive scheme and My Mac. `Package.swift` and `swift build` remain supported. Development requires Xcode 26 or later with the macOS 26 SDK; the Liquid Glass UI is availability-gated for older runtime systems. The package minimum is macOS 14; the pinned backend builder currently produces an Apple Silicon executable.

Build the backend with `python3 scripts/build-rclone-allocation.py`. It downloads and hash-checks the sources listed in `vendor/RCLONE_BUILD.json`, applies the patches and writes `build/backend/rclone`, matching notices and `backend-source.tar.gz`. The pinned license collector uses the same Go toolchain; corresponding sources include vendored dependencies for an offline module rebuild. It builds dependencies in a private temporary directory and removes that directory afterward. Build output is ignored by Git.

Run `scripts/build-app.sh` to package a certificate-signed app. Packaging copies and signs the backend/helper, seals resources, records source hashes and checks signing continuity. Stop the app process before rebuilding its output package. Workers launched by this version run from private, versioned copies outside the bundle, so an Xcode stop/rebuild/run can recover the existing drive without stopping uploads. Packaging still refuses to overwrite a running app, helper, or legacy worker inside the output bundle.

Optional build overrides: `CLOUDDRIVE_BACKEND` selects an already-built patched backend, `CLOUDDRIVE_BUILD_PATH` selects an external Swift scratch directory, and `CLOUDDRIVE_APP_OUTPUT` selects the output bundle. `CLOUDDRIVE_ADHOC_ONLY=1` explicitly builds a UI-only preview without selecting a certificate or accessing Keychain signing identities; the app refuses credential creation/migration in that mode.

Do not run a second CloudDrive build while another build owns the drive. Development builds use the same bundle identity, Keychain service and application-support directory by default. App data is under the current user's Application Support directory, never in this repository. Do not copy it into source control.

## Xcode project

Build the backend once with `python3 scripts/build-rclone-allocation.py`, then open `CloudDrive.xcodeproj` and press ⌘R. The native app target depends on the native CloudDriveHelper target. Its final build phase uses `scripts/package-app.py` to embed the backend/helper, licenses and build metadata, then sign all executable components using `scripts/signing.py`. Xcode's separate signing pass is disabled so it cannot replace the stable signature.

The CloudDrive target's Build Settings → User-Defined contains `CLOUDDRIVE_SIGN_IDENTITY` (optional full certificate fingerprint), `CLOUDDRIVE_BACKEND`, version/build and `CLOUDDRIVE_ADHOC_ONLY`. Normal builds require a stable certificate. For a UI-only preview set `CLOUDDRIVE_ADHOC_ONLY` to `1`; saved-connection creation/migration remains disabled. These machine-specific settings should not be committed. Debug and Release both package a complete app. Stop the app in Xcode before rebuilding. The relaunched app recovers the existing worker and mount. Do not run it alongside the installed app.

Command-line equivalent:

```sh
xcodebuild -project CloudDrive.xcodeproj -scheme CloudDrive -configuration Debug -derivedDataPath build/Xcode build
```

The output is `build/Xcode/Build/Products/Debug/CloudDrive.app`. Tests remain in SwiftPM (`swift test`); the Xcode scheme does not launch the app as a test host or connect to the owner's drive during tests. Regenerate the checked-in project after adding/removing Swift files with `python3 scripts/generate-xcode-project.py`. No third-party generator is required.

## Rename compatibility

CloudDrive is the new app, package, executable and helper name. Build overrides use the `CLOUDDRIVE_` prefix. Existing remote prefixes are loaded unchanged; `clouddrive` is only the default for new connections.

The historical `local.bucketdrive.app` signing/bundle identifier, `local.bucketdrive.r2.v2` and `local.bucketdrive.r2` Keychain services, `Application Support/BucketDrive` state directory and `bucketdrive` worker-control username are intentionally retained. They preserve signing requirements, saved credentials, preferences, ownership locks, pending cache and worker authentication. These are compatibility values, not app branding; do not bulk-replace them. The mount subdirectory remains `Drive`.

Workers are copied to private `Application Support/BucketDrive/Workers/<SHA-256>/rclone` paths before launch. Existing copies are validated and never overwritten. Bundle replacement therefore cannot change a running worker executable. Old worker copies are retained; no automatic cache or executable cleanup runs during recovery.

Recovery uses the private session record, exact process UID/start time/path, authenticated control PID, destination/cache binding and recorded NFS filesystem/port. It does not compare a running worker to the new app's bundled backend. This also permits recovery of legacy workers launched from older app locations. Interrupted launches without a recorded process start identity still require their launch digest to match the discovered executable. Ended sessions can be retired after validating the destination, PID vacancy and mount provenance even when the old binary no longer exists.

Sparkle installation remains gated on safe ejection and worker exit. Local source builds do not replace or update an installed release automatically.

## Tests and qualification

```sh
swift test
python3 -m unittest discover -s Tests/Signing
python3 scripts/qualify-local.py
python3 scripts/qualify-cloud-cache.py
python3 scripts/qualify-finder-allocation.py
python3 scripts/qualify-transfer-controls.py
```

The native harnesses create private temporary fixtures and use the built backend. They require macOS native NFS mounting support. Normal unmount and confirmed worker exit precede successful fixture cleanup. Failures retain generated artifacts; never recursively remove a mounted fixture.

The default tests/harnesses use generated local data, loopback services and synthetic credentials. They do not need your R2 keys. The app's explicit connection test is different: it writes a disposable fixture to the connection selected in the app and independently downloads/checks it.

The optional `experiments/streaming-nfs` directory is its own Go module. Its README describes the separate toolchain and synthetic-store tests. It is not compiled into the app. Build its pinned toolchain using the documented explicit path/archive options; no private development-machine toolchain is included.

## Contributing

Keep worker recovery, mount ownership and accepted pending bytes intact. Preserve the distinction between copying locally, uploading, remote publication and independent verification. Do not interpret unknown status as idle or a vanished queue row as a verified upload.

Submit changes with focused tests and note whether validation used local fixtures, a signed package or an actual provider. Never include credentials, runtime records, screenshots of private files, crash dumps or personal account details. Generated app bundles, signing identity pins, test artifacts and caches stay outside version control.

## Finder grouping qualification on November 6, 2026

On this Mac, the installed CloudDrive build 39 and Helumi each handled Finder’s **File → New Folder with Selection** on twelve existing folders containing 765 files. The timed interval began when the test invoked the menu command and ended when the original twelve folders had disappeared and all twelve appeared inside Finder’s new folder. CloudDrive took **1.250 seconds** and Helumi took **0.994 seconds**. These are individual end-to-end observations, including UI automation overhead. A separate attempt to invoke the Helumi command stopped before clicking when Finder lost focus. The test reselected the generated folders and measured the successful invocation.

The CloudDrive fixture used twelve different payloads in an isolated R2 namespace. Each folder contained 63 or 64 file records sharing its folder’s payload. Verification checked all 765 destination paths and sampled each distinct payload through Finder. After the journal drained, the signed diagnostic listed the moved directories, verified the names and immutable locators of all 765 records, and fetched all twelve distinct backing objects directly from R2 using their validators. The diagnostic confirmed a normal unmount and clean owner shutdown. Cleanup removed 235 generated objects, and an independent listing found zero remaining. This exercises grouping existing content. Copying new content and transferring large files have separate qualifications.

To reproduce, register a single signed CloudDrive filesystem extension at the installed application path, mount Helumi, and use the script in an unlocked Finder session. Choose a fresh report path for each run.

```sh
python3 scripts/qualify-native-finder-project.py --app /Applications/CloudDrive.app --large-group --report build/finder-group-run.json
```

Build 39 app executable SHA-256 `7c86d8727f856f6330404253a4f0303f18d1f5c4de193c085dc37b5778ac1f07`. Signed application’s final report SHA-256 `653134548b41051f3c182b3ae47efc2bb7801de158434aa974e452cae286d378`.

The final installed build 45 repeated the literal grouping command on a fresh 765-file fixture. CloudDrive took **1.124 seconds** and Helumi **1.266 seconds**. All 765 names and locations matched after the move. The final signed verifier fetched the published R2 records independently, checked the expected grouped layout, compared all twelve distinct immutable backing payloads and confirmed clean unmount and shutdown. Cleanup removed 217 generated R2 keys and verified the fixture prefix was empty. Its report SHA-256 is `262b7e2a5e6d5e099a5cc89ff64b31cbe83754f95a131607cdc115aef3cf2cff`.

### Initial copy of a Logic project package

A separate test duplicated a generated `.logicx` package from the Mac to each mounted volume through Finder. Its 12 takes each contained a Media folder and one 32 KiB payload. Each row used the same source on both volumes, with Helumi first. Timings are individual foreground observations in seconds. All twelve payload hashes matched on Finder return and on an independent R2 read after publication.

| Installed build | CloudDrive | Helumi | Qualification |
| --- | ---: | ---: | --- |
| 40 | 5.565 | 1.483 | Finder duplicate. The verifier arranged the generated payload folders after timing. |
| 42 | 5.122 | 0.935 | Same package. Cached signing handles retain per-connection live identity validation. |
| 43 | 3.341 | 0.987 | Original package layout preserved and verified against the published R2 namespace. Both volumes had zero AppleDouble companions after copying. |

On build 43, the measured interval contained 15 write calls, 38 creates, 46 extended-attribute updates and 40 other attribute updates on CloudDrive’s synthetic mount. CloudDrive also made 93 directory-list requests accompanied by 93 separate volume-revision requests. Apple’s FSKit diagnostics counted 78 incomplete attribute responses on that mount. The missing standard attribute was the BSD flags field. These counts led to explicitly reporting flags and returning directory identity, contents and revision together in one response. Use a new matched on-device run to establish the effect of those later changes.

Build 44 copied this same package in **1.849 seconds** and produced zero AppleDouble files. The paired Helumi run took 11.064 seconds. Two warm repeats using the exact source took **1.295 and 1.445 seconds** on Helumi, with all twelve hashes matching. The paired outlier makes a single speed ratio misleading. During the CloudDrive run, the FSKit diagnostic count for incomplete attributes fell to zero, as did separate volume-revision calls during enumeration. The original 370 node lookups on build 43 fell to 183 on build 44. These changes shipped alongside optimized Swift compilation and write-path improvements, so the timing comparison measures their combined effect.
