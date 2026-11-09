# How Helumi handles moves

**Helumi 0.3.18, build 45 · arm64 OrbitFS extension · static inspection, November 6, 2026**

The shipped extension exposes an item-level move by stable identifier, a name and a destination parent. Its Finder-facing rename accepts an optional item to replace. What happens when a user drags one populated folder onto another populated folder of the same name remains an open runtime question. A Finder prompt, an application enumerating the children and a single filesystem rename can yield different outcomes. This distinction matters for a move such as `Logic Projects` into a backup containing its own `Logic Projects`.

## From Finder to the provider

| Observation | Evidence and implication |
|---|---|
| Finder-facing entry point | The FSKit selector at `0x1000124d0` accepts source item, source directory, old and new names, destination directory, optional item to replace and a reply handler. In the adjacent adapter block, `0x1000123ec` branches to `OrbitDrive.rename(_:to:in:replacing:)` at `0x1000ab680`. This gives the engine the identity of a prospective replacement. [M1] |
| Local tree | The first async continuation resolves tree nodes at `0x1000ab74c` and `0x1000ab78c`. It enters and releases unfair locks in the block beginning at `0x1000ab7c8`. Other branches call the identified `DriveTree.update` function at `0x1000ab9c8` and `0x1000aba14`. The inspected locks cover short local work. Ordering among independent Finder requests and the moment Finder receives its reply still require a trace. [M1, M2] |
| Conditional replacement | A branch starting at `0x1000ab910` checks flags and item identity. One path loads the optional replacement payload from the rename context at `0x1000ab94c` and tail-calls `OrbitDrive.remove(UInt64)` at `0x1000ab974`. This establishes an item-removal path. The exact eligibility checks, remote deletion order and crash behavior require additional evidence. [M1, M2] |
| Provider request | `OrbitAPI.move(id:name:parentId:)` begins at `0x10005c07c`. Its continuation tail-calls `OrbitAPI.update(id:name:parentId:modifiedAt:)` at `0x10005c194`. The update code constructs the field strings `name`, `nameHash` and `parentId` at `0x100154cb4`, `0x100154d04` and `0x100154d68`. The provider has an item-addressed metadata operation. Server-side implementation, number of requests for a folder merge and content-transfer behavior remain unknown. [M1, M2] |

## Concurrency

The compiled default configuration uses **6 small-upload slots, 4 large-upload slots and 8 metadata slots**. The configuration initializer at `0x10008794c` stores the three counts in distinct fields. Their individual initializers are at `0x10001ab0c`, `0x10001ab14` and `0x10001ab1c`. The default small-file limit at `0x10001ab04` is 8 MiB. The default direct-transfer minimum at `0x10001ab24` is 128 MiB. The metadata getter at `0x100087638` reads the same configuration field written by the initializer. [M1]

These values describe tunable defaults. Effective settings, the queue used for a particular rename, head-of-line blocking, per-parent serialization and saturation during a large Finder move remain unmeasured. Use separate counters for local rename acknowledgments, metadata publication in flight and upload work in flight when comparing implementations. In particular, eight metadata slots provide no measured Finder moves-per-second figure.

## Collision behavior

The binary contains a device-labelled conflict-name generator, `ConflictNaming.name(for:device:attempt:)`. Its implementation appends the literal ` (Conflict from `, the device label and a closing parenthesis. From attempt 2 it inserts a space and attempt number before the closing parenthesis. A final nonempty extension follows the suffix. Instructions at `0x10016605c`, `0x100166084`, `0x1001660ec` and `0x100166120` anchor the reconstruction. For an input of `Take.logicx` on `Studio Mac`, this predicts `Take (Conflict from Studio Mac).logicx` and then `Take (Conflict from Studio Mac 2).logicx`. These are worked examples from the instructions. [M2]

There is a separate `OrbitAPI.commitContents` conflict-name callback taking a remote item and attempt number. The shipped `DriveError.errno` getter at `0x100045f74` also maps distinct error variants to `EEXIST` and `ENOTEMPTY`, among others. These findings support at least three possible outcomes across different operations: an explicit replacement, a surfaced filesystem error and preservation under a conflict name. The inspected evidence does not select an outcome for every same-name Finder gesture or prove a recursive merge of nonempty directories. [M2]

## Runtime checks needed to settle the populated-folder case

Use a separate Helumi test account and disposable mounted volume. No configured disposable account was available for this inspection. No personal volume or project was used.

1. Create two populated same-name folders under separate parents. Include a source-only file, destination-only file, same-name/different-bytes file, nested empty folder and same-name Logic package containing different synthetic bytes. Capture both initial trees and hashes.
2. Drag in Finder and record the exact offered choices. Recreate the fixture for each offered choice. Separately invoke POSIX rename with the same layout, recording its result and errno. Report the two entry points independently.
3. Inspect preserved bytes, original and resulting names, empty folders, packages and any duplicates after the UI completes. Reopen from a second clean test client after publication to verify durability.
4. Repeat unrelated sibling moves and two competing moves to the same target, recording monotonic dispatch and reply timestamps, provider publication completion, errors and eventual convergence. Repeat once offline and reconnect. Include a reader holding the old target open throughout replacement.

## Evidence and reproduction

The inspected file was `/Applications/Helumi.app/Contents/Extensions/OrbitFS.appex/Contents/MacOS/OrbitFS`, universal SHA-256 `ec9aa769087937afa289b9c70c9b468fd32eb035c959ea232c8c48b747cd40d0`. All addresses above are unslid arm64 virtual addresses. REA supplied the demangled symbols. Apple's LLVM disassembler supplied the static instruction cross-check after the REA objdump wrapper's symbol filter was rejected by the installed LLVM version. Reproduce with `lipo -thin arm64` into a temporary analysis directory, `nm -an`, `swift demangle --compact` and `xcrun llvm-objdump -d` against the extracted slice. No runtime hooks or binary edits were used.

- **M1** — REA `ev_56b742f4ef0560d173a9a1ff93c43d72e2d9c8f0b661130ce0cb62070e0b9499` identifies configuration fields, rename and provider move.
- **M2** — REA `ev_47ad462c9b84579e9d3ff0c5e8c1fb5c1a3ad13d5e21d4c08abe0b17576c5dc9` identifies tree lookup/update, remove, provider update, commit conflict callback and conflict naming.

The selected REA records are retained locally. The instruction addresses above are supplementary LLVM observations against the same artifact.
