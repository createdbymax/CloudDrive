# Third-party code

The MIT project license applies to CloudDrive-authored code. It does not replace upstream licenses or notices.

| Component | License | Location |
| --- | --- | --- |
| Sparkle 2.10.1 | MIT | `vendor/SPARKLE-LICENSE.txt` (also bundled in the app) |
| rclone | MIT | `vendor/RCLONE-LICENSE.txt` |
| go-nfs | Apache-2.0 | `vendor/GO-NFS-LICENSE.txt` |
| Experimental vendored go-nfs | Apache-2.0, with retained upstream notices | `experiments/streaming-nfs/third_party_go_nfs/` |

The production backend is built from pinned upstream archives plus the patches under `vendor/patches`. Retain the license files and modification notices when redistributing source or compiled backends. `vendor/THIRD_PARTY_CHANGES.md` describes the allocation changes. The experimental module has separate modification notices.

The source repository does not track compiled backends. The backend builder uses pinned `go-licenses/v2 v2.0.1` to collect dependency license/copyright/NOTICE materials and required library sources under `build/backend/backend-notices`. `MANIFEST.json` binds those materials to the backend digest. Both packaging paths require and bundle this directory as `Contents/Resources/BackendNotices`.

The backend includes dependencies under MPL-2.0 and LGPL-3.0 as well as permissive licenses. Each keeps its upstream license. Full GNU GPLv3 and LGPLv3 texts are included with the notices and backend source archive. Every downloadable release includes `backend-source.tar.gz`: patched rclone/go-nfs, vendored dependencies, upstream licenses, modification notices and `BUILD.sh`. This is the corresponding backend source for rebuilding with modified libraries. CloudDrive imposes no additional restriction on modifying or reverse engineering those components. The Swift application communicates with the separate backend process; the root MIT license does not replace the backend libraries' licenses.

Release finalization verifies the source-archive digest against the bundled manifest and adds it to `SHA256SUMS`. Publish that archive alongside the app ZIP and appcast. Build output and license-tool logs are ignored.

Apple SDK/framework components and Go/Swift tooling are not redistributed here. Build them or obtain them through their official distribution channels.
