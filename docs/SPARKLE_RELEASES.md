# Local updates and GitHub release packaging

CloudDrive pins Sparkle 2.10.1 in SwiftPM and the generated Xcode project. Both packaging paths embed its framework, helper services and MIT license, preserving framework symlinks. Do not edit the Xcode project by hand; regenerate with `python3 scripts/generate-xcode-project.py`.

## User behavior

The app and menu bar offer **Check for Updates…**. Checks are manual and every installation requires user approval. `SUAllowsAutomaticUpdates=false` prevents silent automatic installation even if an older user preference enabled it. No system profile is sent.

Checks require `Drive.canQuit`: no mounted drive, active operation or retained worker record. If the user reconnects during downloading, Sparkle's postponement delegate retains the restart callback and shows an eject notice. Ejecting does not install anything automatically: choose **Install Downloaded Update…** explicitly. The existing application termination delegate independently refuses exit while `canQuit` is false. Updating never forcibly unmounts the drive or stops uploads.

The owner repository `createdbymax/CloudDrive`, public signing key and Keychain account are configured in `release-config.json`. The private key was generated locally in Keychain and is never stored in the project. Normal packaged builds use these defaults; no requests happen until a user chooses Check for Updates. The feed will return unavailable until a stable release with `appcast.xml` is published.

Set `CLOUDDRIVE_DISABLE_UPDATES=1` to package an unconfigured source build that does not start its updater or contact a feed; its update menu item is disabled. Forks should replace the public release configuration. To override the feed and key, supply both `CLOUDDRIVE_SPARKLE_FEED_URL` and `CLOUDDRIVE_SPARKLE_PUBLIC_KEY` to the build. Invalid or incomplete metadata fails packaging.

## GitHub hosting

Use a **public** GitHub repository. No GitHub credentials or access tokens belong in the feed URL or application. The intended layout is:

- Feed: `https://github.com/OWNER/REPO/releases/latest/download/appcast.xml`
- Archive: `https://github.com/OWNER/REPO/releases/download/vVERSION/CloudDrive-VERSION-BUILD-arm64.zip`

A published stable release must contain both `appcast.xml` and its ZIP. Sparkle reads the XML; it does not query the GitHub Releases API. GitHub's latest-release redirect keeps the feed URL stable. Keep tagged ZIP URLs immutable. Prereleases do not become GitHub's latest stable release. The generated feed contains one current full update; beta channels and delta updates are not configured.

Nothing in these scripts publishes to GitHub, creates tags, pushes commits, or submits to Apple.

## One-time preparation

1. The chosen public repository is `createdbymax/CloudDrive`; change `release-config.json` for a fork.
2. Resolve packages with `swift package resolve`.
3. An Ed25519 key has been generated locally in the `clouddrive` Keychain account. This command retrieves the same public key on this Mac (or generates a new key on a new Mac; restore the original backup before releasing):

   ```sh
   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account clouddrive
   ```

   Keep the private key in Keychain and back it up securely. Put only the printed **public key** in build configuration. The preparation scripts do not generate keys automatically. Repository, public key and account command-line options default to `release-config.json`.
4. Select a Developer ID Application identity using `CLOUDDRIVE_SIGN_IDENTITY` (full certificate fingerprint). The current development signing baseline enforces signer continuity; switching from Apple Development to Developer ID may require a separate release checkout/build baseline and a reviewed Keychain migration path. Do not delete or override the existing baseline to force a release.

## Local draft qualification

This builds a development-signed app, ZIP, checksum, and `appcast.preview.xml` under `build/releases/vVERSION-BUILD/`:

```sh
python3 scripts/prepare-release.py --draft \
  --repository OWNER/REPO --version 0.5.6 --build 15 \
  --public-key PUBLIC_KEY
```

Draft feeds are unsigned and intentionally not named `appcast.xml`. Do not distribute them. Packaging tests can use a synthetic public key and a placeholder repository without generating any private key; such a build cannot accept genuine signed updates.

## Distribution preparation (requires separate external authorization)

Omit `--draft` to stage a Developer ID signed app with hardened runtime and secure timestamps. Always increment the integer build number. Supply `--previous-appcast PATH` with a local copy of the last published feed to reject duplicate or decreasing build numbers.

```sh
python3 scripts/prepare-release.py \
  --repository OWNER/REPO --version 0.5.6 --build 15 \
  --public-key PUBLIC_KEY --previous-appcast /path/to/previous/appcast.xml
```

This stops after building the app. Notarization is a separate operation because it sends the binary to Apple. After authorized notarization and stapling, rerun the identical command with `--finalize`. Finalization checks the staged metadata and signature, validates stapling and Gatekeeper, creates the ZIP, signs it using the `clouddrive` Keychain account and verifies the Ed25519 signature against the embedded public key. It writes `appcast.xml`, `SHA256SUMS` and `PREPARATION.json`. Nothing is uploaded.

After approval to publish, upload the final ZIP and appcast to the matching GitHub release. Ensure every stable release selected by GitHub's latest redirect has the feed asset. Test the public feed and complete an update from an actual older notarized build before treating the updater as qualified. Include mounted-drive, reconnect-during-download, pending uploads, failed eject, cancelled installation, relaunch, credentials and login-item continuity in that qualification. Local guard tests and development-signed packaging are not a notarized end-to-end update test.

Reference: [Sparkle setup](https://sparkle-project.org/documentation/) and [updater delegate](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html).
