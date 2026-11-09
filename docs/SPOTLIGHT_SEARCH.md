# Spotlight-style drive search

Option–Space opens a floating native search panel on the pointer's display while CloudDrive is running. The dashboard, menu bar, and Command–Shift–F open the same panel. Option–Space toggles it; Escape, clicking outside, or changing focus dismisses it. If another app owns Option–Space, CloudDrive reports the registration failure in its menu and keeps menu access available. No Accessibility or Input Monitoring permission is requested.

The field expands from a search icon, the results unfold beneath it, and a highlight follows keyboard/mouse selection. This adapts [Arc's expanding search](https://uiarc.dev/components/expanding-search) and its published motion presets to Spotlight proportions. A standalone SwiftUI reference is in `experiments/uiarc-expanding-search/`. Native typography, symbols, and spring solvers differ from the browser; pixel-equivalent rendering is not claimed.

The panel shows at most six saved entries, searches file names and paths with the existing local token-prefix index, emphasizes matching text, and displays folder and size metadata. Up/Down wrap the selection, Return opens, and Command–Return reveals in Finder. Opening requires Finder browsing to be connected and a safely resolvable object path. Search itself works offline and neither starts indexing nor downloads file contents. Indexing continues according to the app's existing settings. Empty queries show indexed files, not tracked recents. The sliders button opens the complete search/index window with extension/size filters and indexing controls.

On macOS 26+, surfaces use SwiftUI's native Liquid Glass. macOS 14–15 use system material. Reduce Transparency uses an opaque system background; Reduce Motion removes width/position travel and moving selection animation. Light/dark colors follow the system. The popup has its own debounced, cancellation-aware query model, so it does not overwrite the full search window's results. Destination changes reject outdated responses.

## Local verification

November 3, 2026. Isolated synthetic metadata only; no real bucket connection, Keychain access, worker, mount, installed-app replacement, or release.

- Spotlight query tests cover out-of-order responses, query invalidation, wraparound selection, errors, and preservation of the full index window's query.
- Native panel test covers saved-index restore, key/floating/transparent window properties, dismiss/reopen, and Escape handling.
- A separate preview app was inspected through native UI automation: saved files render, typing filters the index, Return shows the connection requirement, and Escape dismisses. Light and dark appearances and the full-index controls were verified. Light appearance was captured from the real composited window. Global shortcut registration succeeded; automated key injection could not reliably validate physical system-wide Option–Space or arrow navigation because activating the app changes key focus away from its nonactivating panel. Those physical-key checks remain manual, as do multiple Spaces/displays and older macOS fallbacks.
- Ordinary NSView bitmap snapshots omit Liquid Glass layers and are not suitable visual evidence. Use a composited native window screenshot.

Reproduce:

```sh
swift test --scratch-path build/SpotlightVerification --filter 'SpotlightSearchTests|SpotlightPresentationTests'
python3 experiments/spotlight-preview/build.py
open build/CloudDrive-Spotlight-Preview.app
```

The preview uses a temporary six-file catalog and its own bundle ID. It never enables automatic updates or accesses the real app's connection; quitting removes its temporary data. The build helper uses testable SwiftPM objects from the preceding test command and is intended only for local development.

Final checks: the complete Swift suite passed **249 tests with zero failures**. After final motion/focus changes, all **5 Spotlight tests** passed again. The regenerated Xcode project built and packaged a local ad-hoc app successfully at `build/SpotlightXcode/Build/Products/Debug/CloudDrive.app`. The standalone Arc source passed Swift typechecking.
