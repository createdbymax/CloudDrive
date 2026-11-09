# TextEdit and Finder on a personal R2 drive

The November 6 test used the installed CloudDrive build 45, TextEdit, Finder, and the mounted personal R2 drive. Documents used in this test contained disposable text. The tested editor was TextEdit.

## Saving an edit

TextEdit opened a plain text file on the drive, added a second line, and saved it. After closing the document and reopening it with TextEdit’s Open dialog, the editor showed both lines. An independent authenticated reader followed the published R2 root through its directory and file indexes, fetched the named file’s backing object, and verified all 115 bytes. Its SHA-256 was `2035b9ac5a7b0cae71f403b35d1dd34e916055af7424522377a2d47345bd69a1`.

When closing the edited document, TextEdit warned that permanent macOS version storage was unavailable on the volume. The latest save survived closing and reopening. The test left the warning preference at its original setting.

## Rename, search, and Finder Trash

* The app’s search found a disposable file under its original name. After a rename in Finder, searching for the old name returned no matches and the new name returned the file.
* Finder’s Move to Trash placed a test file in the mounted volume’s per-user Trash. A newer, different file was created at its original path. Put Back displayed Keep Both, Stop, and Replace. Choosing Keep Both preserved the exact newer contents at the occupied path and restored the original contents under a name ending in “ copy.txt.”
* On the installed Helumi mount, the same Finder Move to Trash command warned that Finder would delete the item immediately. The prompt was cancelled. This tests what Finder presented, independently of Helumi’s own retention system.

## Offline availability and menu forwarding

CloudDrive’s installed Finder menu showed Keep Downloaded, Free Up Local Space, and Show CloudDrive Activity. On build 45, choosing either file action dismissed the menu without visibly opening the expected app confirmation. Delivering the same request directly to the installed app opened the confirmation with the selected path. Once the file was published and pinned, its native availability attribute reported `availableOffline`. Freeing it changed the attribute to `remoteOnly`. A positive visual badge was not observed in that Finder list view.

Helumi showed an Uploading status beside the new disposable file and offered Keep on This Mac. Creating a relative symbolic link to the test file succeeded on Helumi, and reading it yielded the correct bytes. Creating a hard link returned operation-not-supported. CloudDrive currently rejects both link types.

Finder’s callback can retrieve the current selection directly. The updated extension gives the separate commands their own selectors, validates the selected paths and mounted filesystem in the callback, and forwards the request to its containing app. The app still confirms the full selection before changing offline storage. The Apple API documents valid selection access inside both menu construction and its actions. [Finder Sync selected item URLs](https://developer.apple.com/documentation/findersync/fifindersynccontroller/selecteditemurls())
