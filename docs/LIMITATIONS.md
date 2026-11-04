# Current limitations

CloudDrive is an early development app for one user, one R2 connection and one actively writing Mac.

- Writes stage the complete file locally before cloud upload. Large copies can require their full size in temporary space. Cache size/reserve targets are soft limits for active/dirty data, not hard quotas.
- Eligible uploaded/read cache data is automatically reclaimed. Metadata, active reads and pending uploads still use local storage. Originals outside the drive remain unchanged.
- There is no supported trash, old-version restore, offline pinning, end-to-end encryption, sharing service or concurrent-Mac conflict resolution. Finder deletion deletes the remote object. Keep originals and use a dedicated prefix.
- Finder uses an NFSv3 server bound to loopback. Other processes/users on the same Mac can access that NFS listener; its data path does not have per-user authentication. The control API has separate authentication.
- Worker/mount ownership checks and bounded control calls preserve uncertain state instead of starting another writer or force-unmounting. A dead or unresponsive NFS worker can still leave native clients waiting and require recovery.
- The app blocks normal quit until safe eject. Window close leaves the background drive running. Force Quit, process termination, logout and power loss cannot be treated as normal safe shutdown.
- Foundation allocation values and native Finder Get Info can differ or remain cached. Allocation patches preserve logical size and report available cache allocation; they do not guarantee that Finder refreshes immediately.
- Apple Silicon downloads are Developer ID signed and notarized. A complete long-duration workload/failure matrix and an update from a previously published notarized version remain unqualified. Manual Sparkle update checks and signed release preparation are implemented; see [release preparation](SPARKLE_RELEASES.md).

The separate streaming experiment proves early chunk upload and restart ordering using synthetic loopback services. It has restricted filenames/operations, explicit-only final publication, request/transfer amplification and a native worker-death waiting issue. It is not an app feature or a substitute for production qualification.
