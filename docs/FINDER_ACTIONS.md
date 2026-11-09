# Finder actions

The optional `CloudDriveFinder.appex` adds **Keep Downloaded…**, **Free Up Local Space…**, and **Show CloudDrive Activity** to the native owned-drive context menu. Up to 32 selected items are supported within a bounded 16 KiB request URL. The app confirms cache mutations, resolves the selection through its authenticated namespace owner, and preserves dirty/pinned/open-generation protections.

The FinderSync extension is sandboxed. It never reads a storage credential or owner IPC token, and never opens the owner socket. It filters selections to the expected mount location and filesystem type, then sends a `clouddrive://finder` URL to the app. These URLs are untrusted input: other applications can send them too. `FinderActionRequest` rejects extra/duplicate fields, duplicate normalized selections, traversal, malformed paths and foreign URL authorities; the receiving controller must independently verify the exact live mount/resource/session before resolving each logical component. URL parsing alone does not establish ownership. Confirmation is therefore intentional.

The implementation provides actions and bounded multi-selection; Finder badges remain separate. Extension activation and actual Finder menu behavior require a signed installed candidate and remain unqualified until exercised on the target Mac. The extension compile is not that evidence.

## Build and package

From the repository root:

```sh
python3 scripts/generate-xcode-project.py
xcodebuild -project CloudDrive.xcodeproj -target CloudDriveFinder -configuration Release CODE_SIGNING_ALLOWED=NO build
```

Pass `CLOUDDRIVE_INCLUDE_FINDER=1` to the normal inactive-app packaging workflow. If the built extension is outside the products directory, set `CLOUDDRIVE_FINDER_EXTENSION` to its `.appex` path. `finder_packaging.py` checks module identity/entry point, embeds under `Contents/PlugIns`, signs with the existing selected identity, and records its executable digest in `BuildInfo.json`. Missing requested output fails packaging. This does not enable the extension in macOS or restart Finder.

FSKit remains independent: its Apple profile and `CLOUDDRIVE_INCLUDE_FSKIT=1` gate are still required to mount the native drive. Run `python3 scripts/check-fskit-readiness.py /absolute/path/to/candidate.app` for a read-only prerequisites report. A ready report is permission to begin an activation test, not proof of activation, notarization or mounted correctness.

## Qualification

1. Test malformed URL, sibling path prefix, bounded multi-selection and literal-percent/Unicode round trips with `FinderActionRequestTests`.
2. Enable the signed Finder extension using macOS's extension UI; observe the menu only inside the expected mounted drive.
3. Select multiple files; confirm the entire scrollable path list in the app; verify all bytes remain readable offline after completion.
4. Select a clean cached file; confirm Free Up Local Space; verify subsequent cold read downloads correct bytes. Pending local content must not be discarded.
5. Dismiss confirmation, include a missing last selection, replace the mount after lookup, or send an outside-path URL; verify no mutation. The controller resolves every selection before modifying any cache policy and revalidates its owned mount before each mutation.
6. Choose Activity; verify the app opens management without changing data.

The adapter emits `OwnerRPC` signpost intervals in the `local.bucketdrive.app.filesystem` subsystem. They measure owner round trips including IPC and scheduling; they exclude Finder preflight and visible redraw. Operation names are public; paths, filenames, credentials and payloads are not logged.

Multi-selection uses `paths=<JSON array>`; legacy single-selection `path=` URLs still work. The two forms cannot be combined. The controller resolves every item first, then applies authenticated cache actions sequentially. A provider/runtime failure after mutations begin can leave earlier items completed; it does not claim a cross-item atomic transaction or discard protected dirty data.
