# Signing and Keychain

CloudDrive needs a stable certificate signature for reliable saved-connection access across changed builds. Ad-hoc signatures are tied to a specific build and do not provide this continuity.

1. In Xcode, open Settings → Accounts, select your team and Manage Certificates.
2. Create or select an Apple Development certificate with its private key available on this Mac.
3. Run `security find-identity -v -p codesigning` locally. Do not paste private keys or account details into an issue.
4. Build the CloudDrive scheme in `CloudDrive.xcodeproj`, or run `scripts/build-app.sh`. If several supported identities exist, set `CLOUDDRIVE_SIGN_IDENTITY` to your chosen full certificate fingerprint in the CloudDrive target’s user-defined Build Settings or for the build command. Both routes use the same signing helper and identity pin.

The first successful signed build records its identity/requirement under ignored `build/signing/`. Later builds must satisfy that requirement. Do not commit this local state or delete it merely to bypass a failed signer-continuity check. Changing signer/team/channel is a separate release decision.

The app's bundle identifier is `local.bucketdrive.app`. Credential creation/migration requires a valid certificate-signed app with that identifier. Changing the identifier needs coordinated changes to the signing script and credential guard; it is not only an Info.plist edit.

Connections use macOS Keychain with default app-specific access rules. The current service is `local.bucketdrive.r2.v2`; explicit migration from the legacy service preserves the original item. Automatic recovery does not open hidden authorization prompts. A first approval or unlocking a locked Keychain can still be necessary.

For a UI-only preview, run `CLOUDDRIVE_ADHOC_ONLY=1 scripts/build-app.sh`. This explicit mode skips certificate/Keychain identity selection and uses an ad-hoc signature. It cannot save or migrate credentials and is not a credential-capable release. The older `CLOUDDRIVE_ALLOW_ADHOC=1` option permits fallback only and still prefers an available supported certificate. Never weaken Keychain access rules to make an unsigned preview work.

If certificates exist but are not valid for signing, inspect their validity and chain. Obtain matching public intermediates from [Apple PKI](https://www.apple.com/certificateauthority/) with normal trust; do not mark arbitrary certificates Always Trust or create more leaf certificates as a workaround.

Contributor builds use your own development signing identity. You do not need the maintainer’s Developer ID certificate, notarization credentials or Sparkle private key. For public downloads, Developer ID signing, notarization and signed update assets are handled separately; see [release preparation](SPARKLE_RELEASES.md).
