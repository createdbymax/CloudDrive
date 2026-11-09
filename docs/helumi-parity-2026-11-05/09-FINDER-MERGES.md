# Finder folder merges on this Mac

On November 6, 2026, Finder was tested against installed CloudDrive build 45 on its personal R2 mount and Helumi on its native volume. Each drive received a fresh, uniquely named disposable tree. Both source and destination contained a folder named `Logic Projects` with a nested `Audio Files` folder and one file with conflicting contents. The destination was named `T5 Backup`. No audio project was opened or edited.

| Finder action | Result on both drives |
|---|---|
| Copy the source folder, then Move Item Here | Finder offered Stop and Replace. Stop left both trees intact. |
| Copy the source folder, then Paste Item | Finder offered Stop, Replace and Merge. Merge kept both distinct root files, both distinct nested files and the newer destination copy of the conflicting file. The source tree remained available. |
| Move Item Here and choose Replace in a fresh tree | The source folder disappeared. The destination contained the source version of the conflicting file and the source-only file. The prior destination-only file disappeared. |

This is why the exact Finder command matters when moving projects into an occupied folder. In this same-volume scenario, choosing Replace replaces the whole destination folder. To combine their contents, use Copy, Paste Item and Merge.

Build 45 also created four hidden AppleDouble files during the merge. Helumi created none. Each CloudDrive companion carried a computed availability attribute and an empty resource-fork placeholder. The availability value describes the file on its current mount and has no meaning when copied to a different item. The FSKit adapter now omits this value when Finder enumerates copyable user metadata. Named reads remain available to Finder badges and native tags remain enumerable. Seven adapter regression tests passed after the change. A mounted retest is recorded separately from the source checks.

The read-only verifier resolved both destination trees from the personal bucket’s published HEAD and commit. It checked immutable directory and file indexes, followed each backing reference, and matched all five merged file hashes and both replacement file hashes. It also verified the independently edited text document in the same run. Both generated merge trees were removed from their mounted namespaces after those checks.

Captured prompts, destination content and independent R2 verification are under `build/merge-logic-parity/` in the private development checkout. The same-volume tests cover an occupied tree with distinct and conflicting names. They do not establish every macOS merge behavior, every kind of project, or how a transfer interrupted after it starts is recovered.
