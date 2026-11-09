# FSKit setup on this Mac

Updated November 5, 2026. The extension compiles, but a working Finder mount also needs a provisioned signature and macOS extension approval. Neither is implied by an unsigned build.

## Current provisioning result — November 5, 2026

After the account was signed into Xcode, `python3 scripts/provision-fskit.py --team EGEBBVL76D --apply` exited successfully with `ready-for-packaging`. The helper validated the FSKit entitlement, profile validity, team and pinned-certificate membership, and strict extension signature. The existing pinned app signer was preserved.

- Extension: `build/fskit-provisioning/Products/Debug/CloudDriveFS.appex`
- Profile: `build/fskit-provisioning/Products/Debug/CloudDriveFS.appex/Contents/embedded.provisionprofile`
- Evidence: `build/fskit-provisioning/provision-23f25d456e804a71b1e1f29749c2aa39.log`
- Profile SHA-256: `778266be1c18a133ec26f2e38d6589f190f1aab3def1dca370f47be2c90c5e36`

This resolves the earlier provisioning blocker. It does not establish installation, extension approval or a mounted Finder qualification; record those separately in [personal drive completion](PERSONAL_DRIVE_COMPLETION_2026_11_05.md).

Earlier on the same date, the automatic provisioning attempt reported **No Accounts** and no matching profile (`build/fskit-setup/automatic-provisioning.log`). That is historical evidence, superseded by the successful run above.

Apple lists FSKit Module for Apple Developer Program and Developer ID provisioning, while the free Apple Developer column has no support mark. The source table uses icons that some text extractors omit. No official profile-free/ad-hoc development route was established in this investigation. Keep the existing profile validation. Sources: [supported macOS capabilities](https://developer.apple.com/help/account/reference/supported-capabilities-macos/), [development provisioning profiles](https://developer.apple.com/help/account/provisioning-profiles/create-a-development-provisioning-profile/).

## Provision the existing extension

`scripts/provision-fskit.py` defaults to a local plan. It targets only `CloudDriveFS` and preserves the existing `local.bucketdrive.app.filesystem` identifier. It never installs the app or activates an extension.

```sh
python3 scripts/provision-fskit.py --team EGEBBVL76D
python3 scripts/provision-fskit.py --team EGEBBVL76D --apply
```

`--apply` authorizes Xcode to communicate with Apple using its configured account. Xcode's automatic-signing service can manage profiles, App IDs and certificates; the helper does not select a new app signer. It validates that the resulting profile authorizes the existing pinned certificate before reporting readiness. If Xcode specifically requires registering the development Mac, rerun with `--register-device` under the same team. Do not switch teams or bundle IDs to hide a provisioning failure.

The helper distinguishes account authentication, signing conflicts and missing profiles, records each attempt in a new private log, and returns the exact extension/profile paths when ready. It uses generic `CODE_SIGN_IDENTITY=Apple Development` for automatic provisioning; an explicit certificate fingerprint conflicts with Xcode's automatic-signing workflow. The subsequent app packaging still uses the pinned fingerprint.

Alternatively, download an existing Mac App Development profile for this exact extension/team from the developer portal. It must be unexpired, grant `com.apple.developer.fskit.fsmodule`, and include the pinned signing certificate. `scripts/fskit_packaging.py` checks these requirements. Do not edit a provisioning profile by hand.

## Package, install and approve

Use the returned paths in the normal inactive-app packaging workflow:

```sh
CLOUDDRIVE_INCLUDE_FSKIT=1 \
CLOUDDRIVE_FSKIT_PROFILE=/absolute/path/to/embedded.provisionprofile \
CLOUDDRIVE_FSKIT_EXTENSION=/absolute/path/to/CloudDriveFS.appex \
python3 scripts/package-app.py /absolute/path/to/inactive-candidate.app /absolute/path/to/products /absolute/path/to/rclone
```

When packaging through `xcodebuild`, shell environment variables alone are insufficient: the generated project defines inclusion flags as `0`. Pass `CLOUDDRIVE_INCLUDE_FSKIT=1` and `CLOUDDRIVE_INCLUDE_FINDER=1` as explicit command-line **build settings**, together with the extension/profile paths. Inspect the resulting bundle for both embedded extensions before installation. Direct `python3 scripts/package-app.py` uses the environment shown above (add `CLOUDDRIVE_INCLUDE_FINDER=1` for FinderSync).

Keep the app/owner signer stable. Before replacing an installed app, retain a versioned backup of its bundle and `BuildInfo.json`, verify the candidate signatures, and ensure its drive is detached and accepted work is protected. Do not delete application support, pending journals or staged file contents during app replacement.

After installing/opening the correctly signed app, Apple documents this approval path:

1. Open **System Settings → General → Login Items & Extensions**.
2. In Extensions, select **By Category**.
3. Open **File System Extensions** using its information button.
4. Enable **CloudDrive Filesystem**.

This comes from Apple's [passthrough filesystem sample](https://developer.apple.com/documentation/fskit/building-a-passthrough-file-system). Use the app's mount command after approval so resource identity, session and recovery state remain coordinated. A successful filesystem-extension compile, a Settings toggle or a passing signature check alone does not prove mounted behavior.

Run `python3 scripts/check-fskit-readiness.py /absolute/path/to/candidate.app` to check packaging prerequisites. Then record actual native mount, directory listing, read/write, rename with an existing handle, independent Finder eject, and restart behavior against an isolated synthetic or explicitly scoped cloud fixture. Distinguish extension approval from FinderSync approval: they are separate extensions.

No profile, signing or activation checks were bypassed during this setup investigation.

## Sandboxed owner socket

FSKit cannot connect to the owner's arbitrary temporary-directory UNIX socket. Host, embedded engine and FSKit now share the same signing-team-prefixed `TEAM.cd` app group; the authenticated owner socket lives inside that group container. Packaging derives the team from the validated FSKit profile and verifies the signed code uses that team. It retains existing certificate and designated requirement checks. No Keychain access-group changes or global temporary-directory sandbox exception is added.

Apple documents that [team-prefixed macOS app groups do not require a separate provisioning profile](https://developer.apple.com/documentation/xcode/accessing-app-group-containers), and that [shared UNIX sockets belong inside the group container](https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.security.application-groups). The FSKit module itself still requires its valid module provisioning profile.

The host and standalone engine receive only the application-groups entitlement. Their team is checked from the certificate signature, not added as the restricted `com.apple.developer.team-identifier` entitlement: adding that entitlement to an unprovisioned executable makes AMFI reject launch with “No matching profile found.” The FSKit extension retains its profile-authorized team entitlement. A copied same-certificate engine with group-only entitlements successfully returned its group resource path during diagnosis.
