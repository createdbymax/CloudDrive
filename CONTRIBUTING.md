# Contributing to CloudDrive

Read README.md, docs/DEVELOPMENT.md and docs/LIMITATIONS.md before making changes. CloudDrive is experimental macOS software; use generated data and a dedicated test prefix, and keep originals.

Open an issue for ordinary bugs or proposed features. Report vulnerabilities privately using SECURITY.md. Include macOS and Xcode versions, the source revision, reproduction steps and redacted output. Never include credentials, personal account details, runtime state or private files.

Keep changes focused. Preserve pending bytes, mount ownership, recovery guards and signing continuity. Unknown worker status must not be treated as idle. Explain whether verification used synthetic local fixtures, a signed package or an actual provider.

Before submitting, rebuild the backend if its inputs changed, run `swift test` and `python3 -m unittest discover -s Tests/Signing`, and regenerate the Xcode project if Swift source paths changed. Native tests require macOS NFS support; see docs/DEVELOPMENT.md. Do not commit build output, app bundles, signing identities or test artifacts.

Contributions are provided under the project's MIT license. Retain third-party licenses and modification notices. No contributor license agreement is required.
