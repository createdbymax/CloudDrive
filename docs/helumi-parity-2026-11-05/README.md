# Helumi parity development dossier

See the [merge, document and reconnection tests](09-MERGE-SAVE-RECONNECT.md) and the [personal-drive parity comparison](08-PERSONAL-DRIVE-PARITY.md) for side-by-side timings, installed behavior and outstanding limits.

## Implementation follow-up

The user subsequently authorized implementation and clarified that BucketDrive is a personal Mac cloud drive: sharing and file requests are excluded. See [implemented changes](IMPLEMENTATION.md) and [current verification](VERIFICATION.md) for the follow-up code work, tests and remaining release gates. The investigation sections below describe the earlier evidence-gathering stage, not the final implementation state.

**2026-11-05 · Reference: Helumi 0.3.18 (45) · Target: BucketDrive/CloudDrive**

This dossier translates fresh inspection of the installed Helumi application and the current BucketDrive working tree into development work. It includes REA native/resource evidence, live interface observations, three independent source/experience/qualification reviews, and implementation requirements. It does not implement the changes or establish exact parity.

## Read in this order

1. [Evidence and parity ledger](01-EVIDENCE-AND-PARITY.md): artifact identities, provenance, observed versus inferred findings, and unresolved reference scenarios.
2. [Engine and filesystem](02-ENGINE-AND-FILESYSTEM.md): current implementation, six engineering work packages, correctness contracts, dependencies and acceptance gates.
3. [Experience specification](03-EXPERIENCE-SPEC.md): compact status window, setup, shared state, transfers, Finder actions, search, settings, motion and accessibility.
4. [Qualification and delivery](04-QUALIFICATION-AND-DELIVERY.md): fixtures, instrumentation, 17 functional scenarios, performance/visual checks, phased release gates and runbook.
5. [Additional feature designs](05-ADDITIONAL-FEATURES.md): recoverable trash, sharing, file requests and encrypted storage/recovery requirements.
6. [Rename, move and collisions](06-RENAME-MOVE-AND-COLLISIONS.md) traces the shipped FSKit and provider paths, scheduler defaults and conflict naming, and specifies the runtime test for populated same-name folders.

7. [Upload pipeline](07-UPLOAD-PIPELINE.md) traces direct Finder writes, app drops, upload admission, adaptive pacing and remote publication.

## Principal conclusions

The older plan remains useful architecture context, but its Helumi 0.3.13 instruction addresses are not current evidence. The installed app is 0.3.18. Its live everyday surface is a compact drive-status card with an Open in Finder action; settings use a native toolbar and grouped controls. Matching the experience means simplifying the daily surface while keeping detailed management available.

BucketDrive already has stable namespace identities, durable operations, staged content, range cache/pinning, managed publication, recovery/export paths and filesystem-adapter work. Implementing these again would waste existing work. The next phase is qualification and targeted completion: signed FSKit activation, actual Finder semantics, provider conditions, scheduling fairness, bounded large workloads and truthful shared status.

Functional parity extends beyond the filesystem. Helumi's visible encryption controls and packaged sharing/request/restore actions require additional data formats, key custody, retention and service behavior. They cannot be reproduced by adding buttons to a direct R2 client. The additional-feature document specifies original interfaces without assuming knowledge of Helumi's server implementation.

## Suggested delivery backlog

| Priority / milestone | Work | Completion evidence |
|---|---|---|
| P0: trustworthy status | UX-01/UX-07; remove contradictory offline/pinning descriptions; prevent revision equality alone from implying confirmed cloud data | Cross-surface state matrix and stale-snapshot tests |
| P0: native drive qualification | ENG-01; signed extension activation, entitlement/profile checks, real Finder IO/lifecycle | Frozen signed candidate and mounted scenario evidence |
| P0: provider correctness | ENG-04/ENG-06; conditions, unknown outcomes, crash recovery and >5 GiB boundary | Isolated provider qualification plus retained hashes/fault logs |
| P1: foreground responsiveness | ENG-02/ENG-03; scheduler fairness, bounded extents/cache/recovery, sustained mixed workload | Latency distributions, memory/disk/request bounds and integrity checks |
| P1: everyday experience | Compact primary window; UX-02–UX-06; keyboard search, per-item activity/pins, Finder context actions | Paired reference/candidate captures, accessibility and input timing |
| P2: recoverable trash | Retention roots, restore conflicts, remote publication and safe GC | Crash/restore/purge matrix |
| Excluded by user | Sharing and public file requests | Personal Mac drive scope |
| Separate format milestone | UX-ENC encrypted storage, migration, device and recovery-key lifecycle | Independently reviewed design and recovery/tamper/migration evidence |

P0 work packages can proceed independently where ownership is separate. Scheduler parallelism must preserve operation dependencies and publication order. Do not remove the serial fallback or legacy adapter before replacement qualification. No time estimates are assigned before signed activation and measured scale limits establish the remaining work.

## Relationship to existing docs

- [Original implementation plan](../HELUMI_FILE_MANAGEMENT_IMPLEMENTATION_PLAN.md): architecture rationale and historical reference evidence.
- [Implementation progress](../HELUMI_IMPLEMENTATION_PROGRESS.md): prior implementation tracking.
- [Verification report](../HELUMI_VERIFICATION.md): previously recorded test/build outcomes. The new dossier inspected existing evidence; it did not rerun the suite.

Use current source plus this dossier to define new tasks. Preserve prior reports as dated evidence. For every milestone label status separately as implemented, fixture verified, mounted verified, provider verified and release supported. Static symbols and successful compilation do not satisfy the other categories.

## November 6 follow-up

The upload pipeline study adds a real 129 MiB Finder copy on the installed Helumi and CloudDrive mounts, including mounted digest checks and a separate R2 readback for CloudDrive. See [Finder and upload pipeline](07-UPLOAD-PIPELINE.md) for timings and evidence limits.

## November 5 investigation limits

Observed live: idle window, menus and General/Storage/Encryption settings. Unobserved live: file operations, sharing, requests, trash/restore, active transfers, faults, exact animations and benchmark behavior. No credentials or recovery keys were read, no cloud fixture was mutated, and no application source was edited. Documentation links and JSON artifacts were checked locally; no runtime test results are newly claimed.

The work fulfills a development-documentation request. Exact functional and experiential equivalence remains a measurable development objective, with unresolved reference scenarios explicitly retained in the ledger and qualification plan.
