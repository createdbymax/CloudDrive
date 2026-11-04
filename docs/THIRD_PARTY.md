# Third-party code

The MIT project license applies to CloudDrive-authored code. It does not replace upstream licenses or notices.

| Component | License | Location |
| --- | --- | --- |
| Sparkle 2.10.1 | MIT | `vendor/SPARKLE-LICENSE.txt` (also bundled in the app) |
| rclone | MIT | `vendor/RCLONE-LICENSE.txt` |
| go-nfs | Apache-2.0 | `vendor/GO-NFS-LICENSE.txt` |
| Experimental vendored go-nfs | Apache-2.0, with retained upstream notices | `experiments/streaming-nfs/third_party_go_nfs/` |

The production backend is built from pinned upstream archives plus the patches under `vendor/patches`. Retain the license files and modification notices when redistributing source or compiled backends. `vendor/THIRD_PARTY_CHANGES.md` describes the allocation changes. The experimental module has separate modification notices.

The source repository does not track a compiled rclone executable; local builds are ignored. Its build downloads additional Go modules under their own licenses. Before publishing a binary/app release, inventory those transitive dependencies, collect all applicable license/attribution/NOTICE materials, and package them with the release. The two top-level license files are not a claim that every transitive binary dependency has been reviewed.

Apple SDK/framework components and Go/Swift tooling are not redistributed here. Build them or obtain them through their official distribution channels.
