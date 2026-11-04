# Contributing

CloudDrive is a small, early project, and I'd love for it to become a community thing. If something bugs you, an instruction is confusing, or you have an idea, feel free to jump in. You don't need to know the whole codebase to help.

Docs, bug reports, accessibility improvements, tests, and code are all welcome. Take a look at the [issues](https://github.com/createdbymax/CloudDrive/issues), or open one of your own. If you're thinking about a bigger change, let's talk about it in an issue first. Small fixes can go straight to a PR, and draft PRs are welcome too.

## Getting started

You'll need an Apple Silicon Mac, Xcode 26 or newer with the macOS 26 SDK, and Python 3. The app itself runs on macOS 14 or newer. The backend script downloads its own Go toolchain.

Fork and clone the repo, make a branch, then run:

```sh
python3 scripts/build-rclone-allocation.py
swift build
swift test
python3 -m unittest discover -s Tests/Signing
```

The backend build takes a few minutes and needs some temporary disk space. Tests use generated local files and loopback services, so you don't need an R2 account or real credentials.

For a UI preview without a signing certificate:

```sh
CLOUDDRIVE_ADHOC_ONLY=1 CLOUDDRIVE_DISABLE_UPDATES=1 ./scripts/build-app.sh
```

That build can't save credentials. To try a full connection, use your own certificate following the [signing guide](docs/KEYCHAIN_SIGNING_SETUP.md). Don't run a development build alongside the installed app—they share local state.

There's more in the [development notes](docs/DEVELOPMENT.md), [architecture overview](docs/ARCHITECTURE.md), and [known limitations](docs/LIMITATIONS.md).

## Sending a PR

Tell me what changed and how you checked it. A screenshot helps for UI changes. For behavior changes, a regression test is useful; for docs, checking the links is enough. If you couldn't run something, just mention it.

If you add or remove Swift files, run `python3 scripts/generate-xcode-project.py`. Rebuild the backend if you change its pins, patches, or notice generation. Leave personal signing settings and generated build files out of the PR.

Please use disposable files when testing. CloudDrive handles real data, so changes around uploads, recovery, or deleting files need particular care. Keep originals, preserve pending uploads, and don't remove a mounted test fixture if cleanup fails.

Don't include keys, private files, or account details in issues, logs, or screenshots. For security bugs, use [private reporting](SECURITY.md).

CloudDrive's own code is [MIT licensed](LICENSE). Keep third-party licenses and notices intact when working on those parts.
