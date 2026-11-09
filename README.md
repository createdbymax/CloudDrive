# CloudDrive

A small macOS app that puts your own Cloudflare R2 bucket in Finder.

Connect a dedicated bucket prefix and use Finder to copy files, group them into folders, rename them and open them. Credentials stay in macOS Keychain.

On a Mac with the signed FSKit extension enabled, this development build offers an indexed personal drive. Setup imports the names and sizes of existing objects without downloading their contents. A move within the drive changes the item's name or parent in the index. Existing R2 objects keep their original keys; after setup use Finder to manage the drive, since the R2 dashboard does not show the indexed folder layout.

Finder can accept files in stages while CloudDrive sends bytes to R2. Keep the source disk connected until Finder finishes and the Mac online until publication completes. A reported Finder success and a verified R2 publication are separate milestones. See [Finder writeback and qualification](docs/FINDER_WRITEBACK.md). Released builds and the legacy mount can behave differently; see [development limits](docs/LIMITATIONS.md).

## Download

Download the signed and notarized Apple Silicon app from [GitHub Releases](https://github.com/createdbymax/CloudDrive/releases/latest). Requires macOS 14 or later. Unzip CloudDrive, move it to Applications, and open it. This is an experimental release; keep originals and use a dedicated test prefix. Intel Macs are not supported by this build.

## Contributing

I'd love for CloudDrive to become a community project. Bug reports, ideas, docs, accessibility fixes, and code are all welcome—even small things help.

Have a look at the [contribution guide](CONTRIBUTING.md) or [open an issue](https://github.com/createdbymax/CloudDrive/issues/new/choose). You can build a UI preview and run the tests without an R2 account or a signing certificate. If you're not sure where to start, ask in an issue.

## Local search

Open **Search Drive…** (Command–Shift–F) to search the automatically maintained metadata inventory. Filename/path searches then work locally and offline, with extension and size filters. Indexing downloads no file contents. Verified uploads and Finder edits update it automatically; outside changes are discovered periodically. Opening uncached files still needs Finder and connectivity. See [local search](docs/LOCAL_SEARCH.md) for behavior and limits.

## Development

Requirements: an Apple Silicon Mac that can run Xcode 26 or later (including the macOS 26 SDK), Python 3, and internet access for the initial backend build. The app itself supports macOS 14 or later. The current pinned backend build targets `darwin/arm64`.

Open **`CloudDrive.xcodeproj`** in Xcode, choose the **CloudDrive** scheme and **My Mac**, then press **⌘R** to build and run the complete app. First build the backend once using the command below and follow [signing setup](docs/KEYCHAIN_SIGNING_SETUP.md). Xcode builds both native Swift targets, bundles the backend/helper/notices and applies the same stable signing checks as the command-line packager. Use Product → Show Build Folder in Finder to locate the built app under `Products/Debug/CloudDrive.app`.

`Package.swift` remains available for SwiftPM builds and the test suite. The Xcode navigator mirrors the repository, including tests, documentation, scripts, assets, experiments and GitHub configuration. Build outputs and ignored local files are excluded. Browsing these files does not add them to the app's build targets; tests still run through SwiftPM. The Xcode project is checked in; no project-generator installation is needed. After adding or removing repository files, regenerate it with `python3 scripts/generate-xcode-project.py`.

```sh
# Build the pinned backend from public sources and local patches.
python3 scripts/build-rclone-allocation.py

# Compile the Swift package.
swift build

# Package the app using your own signing certificate.
./scripts/build-app.sh
```

The first backend build downloads a pinned Go toolchain, rclone and go-nfs, verifies their hashes, applies the allocation patches and builds `build/backend/rclone`. It also collects dependency notices and creates a vendored backend source archive for redistribution. It may take several minutes and use substantial temporary disk space. No backend executable is tracked in the source repository.

The packaged app is `build/CloudDrive.app`. CloudDrive was previously named BucketDrive; existing credential and state identifiers are retained for [upgrade compatibility](docs/DEVELOPMENT.md#rename-compatibility). Follow [signing setup](docs/KEYCHAIN_SIGNING_SETUP.md) before using saved connections. An ad-hoc preview can compile the UI, but cannot save or migrate credentials; normal app use requires certificate signing.

```sh
swift test
python3 -m unittest discover -s Tests/Signing
```

The Swift suite includes isolated native NFS mounts and synthetic file operations. Build the backend first. Tests do not require your R2 credentials. See [development notes](docs/DEVELOPMENT.md) for qualification commands and build details.

## Updates and local release packaging

Sparkle provides user-approved updates with a safe-eject guard. Packaged builds use the public GitHub release configuration in `release-config.json`; checks are manual. Set `CLOUDDRIVE_DISABLE_UPDATES=1` to disable updates in a local build. See [GitHub update hosting and local release preparation](docs/SPARKLE_RELEASES.md). The preparation scripts never publish or submit for notarization.

## Using the app

1. Create or select a private R2 bucket and a dedicated prefix.
2. Enter its S3 endpoint, bucket, prefix and scoped access keys in CloudDrive's setup screen.
3. Choose **Open in Finder**, then drag files into their destination folder. Open **Transfers** from CloudDrive’s menu to see activity.
4. Copy large files from your external disk through the same Finder window. Keep the disk connected until Finder finishes, and keep CloudDrive connected until Transfers finishes publishing to R2.
5. Optionally enable **Settings → General → Open at Login** to start CloudDrive when you sign in. If macOS requests approval, use the Login Items Settings button.

Never put keys in source files or commit them to Git. New Finder copies use temporary local space and verified chunks in a private R2 prefix. See [Finder writeback, recovery and qualification](docs/FINDER_WRITEBACK.md) and [recovery of older direct upload queues](docs/DIRECT_UPLOADS.md).

On the legacy mount, moves use recoverable server-side copy/delete and preserve native child handles. See [Finder moves and recovery](docs/FINDER_MOVES.md) for progress, limits, and validation.

## Project layout

| Path | Contents |
| --- | --- |
| `Sources/` | SwiftUI app, worker controller and helper |
| `Tests/` | Swift and signing tests |
| `scripts/` | Backend build, packaging and isolated qualification tools |
| `vendor/` | Backend version pins, patches and third-party licenses |
| `experiments/streaming-nfs/` | Separate streaming-write prototype; not part of the app |
| `docs/` | Development, architecture, limitations and release notes |

The [streaming prototype](experiments/streaming-nfs/README.md) has demonstrated uploading during native Finder copies with bounded local metadata. It is restricted to synthetic loopback storage and is not ready to replace the app's backend.

## License

CloudDrive is licensed under the [MIT license](LICENSE). Third-party code retains its own licenses; see [third-party notices](docs/THIRD_PARTY.md). See [contribution guidance](CONTRIBUTING.md) and the [security policy](SECURITY.md).
