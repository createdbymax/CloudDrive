# Architecture

The SwiftUI application delegate owns one `Drive` controller shared by the dashboard, native menu, Settings, Transfers and Recovery windows. Closing a window keeps that controller alive.

`Drive` owns the worker lifecycle. It starts a patched rclone backend, serves the chosen R2 prefix over loopback NFSv3, and mounts it using macOS `mount_nfs`. A separate bounded helper performs file operations that could otherwise block the UI. The application does not use a hosted CloudDrive account or proxy R2 data through a separate service.

Workers launch from private, digest-addressed copies outside the app bundle. Recovery validates the recorded process UID/start time/path, authenticated control PID, destination/cache binding, mount filesystem ID and NFS port. A recorded running worker is not compared against a newly rebuilt app’s backend; interrupted launch intents additionally require the original executable digest. Launch intent and session records support interrupted startup. An uncertain worker or mount is preserved for explicit recovery. Eject normally unmounts, checks/drains pending uploads, stops only the authenticated owned worker and confirms exit before retiring its record.

`ControlClient` uses authenticated loopback requests with deadlines, cancellation, response-size limits and no redirects/proxies. Queue identities, transfer counters and directional bandwidth readback are decoded strictly. Presentation does not treat malformed or stale samples as successful completion.

The backend uses full VFS write-back caching. Dirty/open data is retained; clean data is eligible for automatic eviction. Allocation patches expose the actual local payload cache allocation separately from logical remote size. Local physical-storage scans skip the mounted tree and do not hydrate cloud contents.

R2 keys are entered in the app and stored in Keychain. Child-process credentials are supplied through a sanitized environment, not command-line arguments or repository files. Worker control tokens and mount/recovery state live in owner-only application-support storage. They are runtime secrets and must never be exported with the project.

`experiments/streaming-nfs` is an independent prototype module with a private range journal and immutable synthetic S3 chunks. It does not replace this app architecture or change existing object formats.
