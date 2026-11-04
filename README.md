# CloudDrive

A small macOS app that puts your own Cloudflare R2 bucket in Finder.

Connect a dedicated bucket prefix, copy files using Finder, and watch uploads from the menu bar. Credentials stay in macOS Keychain. Files are stored as ordinary objects; uploaded file data is automatically removed from the temporary local cache when eligible.

**Early development software.** The current app stages a whole file locally before uploading it. Deleting a file deletes its remote object; trash and version recovery are not implemented. Keep originals and use a dedicated test prefix. See [current limitations](docs/LIMITATIONS.md).

## Development

Requirements: an Apple Silicon Mac running macOS 14 or later, Xcode with Swift 6, Python 3, and internet access for the initial backend build. The current pinned backend build targets `darwin/arm64`.

Open **`CloudDrive.xcodeproj`** in Xcode, choose the **CloudDrive** scheme and **My Mac**, then press **⌘R** to build and run the complete app. First build the backend once using the command below and follow [signing setup](docs/KEYCHAIN_SIGNING_SETUP.md). Xcode builds both native Swift targets, bundles the backend/helper/notices and applies the same stable signing checks as the command-line packager. Use Product → Show Build Folder in Finder to locate the built app under `Products/Debug/CloudDrive.app`.

`Package.swift` remains available for SwiftPM builds and the test suite. The Xcode project is checked in; no project-generator installation is needed. After adding or removing Swift source files, regenerate it with `python3 scripts/generate-xcode-project.py`.

```sh
# Build the pinned backend from public sources and local patches.
python3 scripts/build-rclone-allocation.py

# Compile the Swift package.
swift build

# Package the app using your own signing certificate.
./scripts/build-app.sh
```

The first backend build downloads a pinned Go toolchain, rclone and go-nfs, verifies their hashes, applies the allocation patches and builds `build/backend/rclone`. It may take several minutes and use substantial temporary disk space. No backend executable is tracked in the source repository.

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
3. Connect, then open the drive in Finder. Use the menu's Transfers item for progress and Settings for upload limits.
4. Eject the drive before quitting. Closing a window leaves the drive running.
5. Optionally enable **Settings → General → Open at Login** to start CloudDrive when you sign in. If macOS requests approval, use the Login Items Settings button.

Never put keys in source files or commit them to Git. Large writes require temporary local space. Copying does not remove the source original.

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
