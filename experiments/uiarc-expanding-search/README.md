# Arc expanding search — SwiftUI reference

A standalone native port of [Arc's expanding search](https://uiarc.dev/components/expanding-search), based on the public component TSX/CSS from [its registry](https://uiarc.dev/r/expanding-search.json). This experiment is separate from the production drive launcher and has no network or index dependencies.

Open `ArcExpandingSearch.swift` in Xcode Canvas. Its preview supplies two synthetic entries. Copy the source into a macOS 14+ SwiftUI target to reuse it.

The port follows the default Arc geometry: 44-point circular button, 360-point field, 18-point field corners, 26-point panel corners, 8-point panel gap, 6-point panel inset, 48-point rows, and 14/12-point title/metadata. It includes delayed input reveal, width/corner spring morph, independently unfolding results, grouped ranking, match emphasis, a traveling highlight, wrapping arrow keys, Enter selection, Escape collapse, clear, suggestions, and reduced-motion support. Only the actual component consumes pointer events inside its reserved lane.

The native version uses SF Symbols and the macOS system font; the source uses Lucide and browser typography. Motion uses Arc's published 0.42-second morph, 0.4-second smooth panel, and 0.26-second selection presets, all with zero bounce. SwiftUI and Motion use different spring solvers, so timing is a native approximation. Those rendering differences mean byte-for-byte pixel equivalence is not claimed. The production Spotlight version intentionally scales this interaction up and applies native macOS glass rather than retaining Arc's opaque website surface.

Validation: `swiftc -typecheck -parse-as-library experiments/uiarc-expanding-search/ArcExpandingSearch.swift` passed with the installed Xcode SDK. Runtime screenshot comparison is still needed before claiming visual parity.
