# Finder merge, document save and reconnection

November 6, 2026. The merge fixtures used disposable folders on the two mounted drives. The document fixture was a plain text file edited and reopened in TextEdit.

## The T5 Backup conflict

On both drives, moving a folder named Logic Projects into a T5 Backup folder which already contained Logic Projects offered **Stop** or **Replace**. Stopping retained both trees. Replacing in a separate test removed the source and destination-only entry and preserved the source bytes. Copying instead offered **Stop**, **Replace**, or **Merge**. Merge retained the newer destination version of the conflicting file and the unique entries from both trees, including nested entries. The five expected payloads matched on both mounts. The independent R2 check resolved the filenames through the published commit and immutable indexes and compared every byte of all five merged files, both move-and-replace results, and the edited TextEdit file. All eight matched.

The copy exposed an implementation difference. macOS wrote hidden AppleDouble files on CloudDrive which contained the drive's computed availability value. Finder's badge extension needs to read that value by name. It does not belong in a user's copy of a folder. The FSKit volume now omits it when listing portable attributes while continuing to answer named reads.

## Plain text document

TextEdit saved an edited plain text file on the personal drive. The tester closed it, reopened it through TextEdit's Open dialog, and verified that the edited line was present. TextEdit reported that permanent document version history was unavailable on the volume. The version-history preference was left alone. See the [TextEdit and Finder action report](09-TEXTEDIT-AND-FINDER-ACTIONS.md).

## Temporary R2 failures

The managed sync worker previously put a network error into the same manual-recovery state as a conflicting cloud revision. Its normal background tick could then see a nonempty queue indefinitely without retrying. OrbitFS contains an upload-retry log message. That observation supports retrying uploads but does not identify Helumi's exact timing or crash guarantees.

CloudDrive now retains the failed managed operation and retries automatically with a delay of up to 32 seconds. It uses the recorded operation ID and the cloud publication receipts to reconcile an interrupted acknowledgement. A true conflict, corrupt payload or unsupported request still needs attention. Manual pause takes precedence. Older saved managed operations explicitly marked offline or with an uncertain provider reply are eligible for the same reconciliation. An interrupted offline download keeps its pin request for a later attempt. The app reports when it is waiting for R2.

The transport qualification uses a loopback tunnel available only to a debug qualification owner in its generated R2 scope. It interrupts that owner's TLS connections and checks that Finder retains its local copy, a transport failure appears in the durable queue, and restoring the route allows independent publication and full cloud readback without pressing Resume. Neither the personal drive's connection nor the Mac's network settings need to change.

## Other Finder checks

On CloudDrive, search found a text file before and after a Finder rename and stopped returning its old name. Finder Trash and Put Back with an occupied original name offered Keep Both, Stop and Replace. Keep Both preserved the newer occupant and restored the older bytes under a second name. On Helumi, Finder warned of immediate deletion. The tester cancelled at the warning, so this comparison covers the Finder prompt only. A Helumi fixture supported a relative symbolic link and rejected hard links. CloudDrive's native drive currently rejects both. Helumi displayed an Uploading badge. A positive CloudDrive badge requires separate visual confirmation.
