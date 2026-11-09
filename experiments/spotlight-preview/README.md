# Isolated Spotlight preview

From the repository root:

```sh
swift test --scratch-path build/SpotlightVerification --filter 'SpotlightSearchTests|SpotlightPresentationTests'
python3 experiments/spotlight-preview/build.py
open build/CloudDrive-Spotlight-Preview.app
```

This disposable app has its own bundle ID and six synthetic catalog entries. It uses no Keychain, real connection, worker, mount, or automatic indexer. Controls let you reopen search and switch light/dark appearance without changing system settings. Option–Space registration lasts only while the preview runs. Quit from the app menu or Command–Q; temporary fixture data is removed on normal termination. This is a local preview, not a packaged release.

The helper links the isolated testable SwiftPM objects, excluding the normal application entry point. It expects the current macOS/Apple Silicon/Xcode build layout; production uses the normal Xcode project/build scripts.
