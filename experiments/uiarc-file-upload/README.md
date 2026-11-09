# Arc file upload — native SwiftUI study

Open `ArcFileUploadStudy.xcodeproj`, select **ArcFileUploadStudy**, and Run. The two Canvas previews show the empty reference and upload/error states. This project is independent of CloudDrive; neither the main Xcode project nor its app sources were changed by this experiment.

`ArcFileUploadView.swift` contains the view, models, vector icons, animation helpers, and an optional demo app guarded by `UIARC_FILE_UPLOAD_DEMO`. Inter is bundled under the SIL Open Font License in `Resources`.

## Behavior

- Native file selection and file URL drops; type/size validation; file rows and accessible status announcements.
- Local simulated upload progress in the demo. **No file contents are read or sent anywhere.**
- Spring-driven row expansion/removal and progress; blur/offset text swaps; delayed progress-bar collapse; drawn completion checks; hover and press feedback; retry and cancellation.
- Reduced Motion uses fades and immediate progress updates. Keyboard focus moves to the adjacent remove button or back to the drop target after removal.
- To try retry, use the **upload states** Canvas preview (interactive mode), or add `--states` under Scheme → Run → Arguments. The prefilled failed row retries using the local simulator.
- To use only selection, initialize `ArcFileUploadView` with no `onUpload`. To implement a transport later, supply its async handler, report progress from 0–100, and honor Task cancellation.

## Reference fidelity

Source: https://uiarc.dev/components/blocks/file-upload and its public registry (`/r/file-upload.json`, `/r/arc-motion-tokens.json`). Measured against the site's default light theme on November 3, 2026.

Uses the reference's Inter 14/12 typography, 1.4 line heights, 92-point drop target, 26/18-point corner radii, padding, neutral OKLCH palette, and 0.24/0.16-second easing. Motion's non-bouncy 0.4/0.26-second visual springs are translated to SwiftUI springs. Lucide-style vectors are drawn natively, including the original cloud's circular arcs.

This is a close native recreation, not a certified pixel-identical rendering: Core Text rasterization, CSS dash distribution, individual file icon paths, and Motion versus SwiftUI spring solvers can differ. The experiment intentionally follows the reference's light theme rather than the app's system appearance.

## Verification

The isolated Debug Xcode build and standalone macOS 14-target type check passed. The native app was launched and the picker and upload progress/completion were observed. The main app was not built or modified for this study.

```sh
xcodebuild -project experiments/uiarc-file-upload/ArcFileUploadStudy.xcodeproj \
  -scheme ArcFileUploadStudy -configuration Debug \
  -derivedDataPath /tmp/ArcFileUploadStudy-build build
```
