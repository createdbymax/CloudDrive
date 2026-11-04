# Security policy

CloudDrive is experimental software. Only the latest source revision is maintained; no stable release or security-support lifetime is promised.

Do not report vulnerabilities in public issues or attach credentials, private filenames, logs containing secrets, or real bucket data.

For the intended repository, use GitHub's private vulnerability reporting page:
https://github.com/createdbymax/CloudDrive/security/advisories/new

This route becomes available only after the repository is published and its owner enables private vulnerability reporting. If unavailable, do not open a public report; wait until the private route is enabled. Fork maintainers must replace this route with their own.

Include affected revisions, expected and observed behavior, and reproduction steps using synthetic data. See `docs/LIMITATIONS.md` for known constraints, including the local unauthenticated NFS listener and lack of trash/version recovery.
