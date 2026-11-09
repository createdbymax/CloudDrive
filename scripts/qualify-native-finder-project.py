#!/usr/bin/env python3
"""Time an identical .logicx folder on a fresh native managed R2 mount and Helumi."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import selectors
import subprocess
import time

spec = importlib.util.spec_from_file_location("native", Path(__file__).with_name("qualify-fskit-mounted.py"))
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)

DUPLICATE = """on run argv
with timeout of 150 seconds
tell application "Finder" to duplicate (POSIX file (item 1 of argv) as alias) to (POSIX file (item 2 of argv) as alias)
end timeout
end run"""

SELECT_FIXTURE = """on run argv
set rootAlias to POSIX file (item 1 of argv) as alias
set expected to {}
repeat with i from 2 to count of argv
    set end of expected to (POSIX file (item i of argv) as alias)
end repeat
tell application "Finder"
    activate
    open rootAlias
    delay 0.6
    select expected
    repeat 40 times
        if (count of (get selection)) is 12 and (target of front Finder window as alias) is rootAlias then exit repeat
        delay 0.05
    end repeat
    if (target of front Finder window as alias) is not rootAlias then error "Wrong Finder window"
    set selectedItems to selection
    if (count selectedItems) is not 12 then error "Wrong Finder selection count"
    repeat with selectedItem in selectedItems
        if (selectedItem as alias) is not in expected then error "Unexpected selected item"
    end repeat
end tell
end run"""

NEW_FOLDER_WITH_SELECTION = """on run argv
set rootAlias to POSIX file (item 1 of argv) as alias
tell application "Finder"
    if (target of front Finder window as alias) is not rootAlias then error "Finder focus changed"
    set picked to (get selection)
    if (count picked) is not 12 then error ("Finder selection changed: " & (count picked))
    repeat with chosen in picked
        if (container of chosen as alias) is not rootAlias then error "Selection outside fixture"
    end repeat
end tell
tell application "System Events" to tell application process "Finder"
    set frontmost to true
    if frontmost is not true then error "Finder is not focused"
    set fileMenu to menu 1 of menu bar item "File" of menu bar 1
    set matches to menu items of fileMenu whose name starts with "New Folder with Selection"
    if (count matches) is not 1 then error "Finder grouping command unavailable"
    if enabled of item 1 of matches is not true then error "Finder grouping command is disabled"
    click item 1 of matches
end tell
end run"""

CLOSE_FIXTURE_WINDOW = """on run argv
set rootPath to (item 1 of argv) & "/"
tell application "Finder"
    repeat with win in (get every Finder window)
        try
            set p to POSIX path of (target of win as alias)
            if p is rootPath or p starts with rootPath then close win
        end try
    end repeat
end tell
end run"""


def require(condition, reason):
    if not condition:
        raise RuntimeError(reason)


def run_finder(script, *args):
    subprocess.run(["/usr/bin/osascript", "-e", script, *args], check=True, timeout=165, stdout=subprocess.DEVNULL)


def digest(path):
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=Path("/Applications/CloudDrive.app"))
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--helumi-first", action="store_true")
    parser.add_argument("--large-group", action="store_true", help="Group 12 folders containing 765 pre-existing files")
    args = parser.parse_args()
    require(not args.report.exists(), "Choose a new evidence path")
    helumi = Path("/Volumes/Helumi")

    def helumi_mount():
        entries = native.mounts_at(helumi)
        require(len(entries) == 1 and " (OrbitFS," in entries[0], "Helumi mount identity unavailable")
        return entries[0]

    identity = helumi_mount()
    app = args.app.resolve(strict=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    executable = app / "Contents/MacOS/CloudDrive"
    result = {"appSHA256": digest(executable), "samples": [], "success": False}
    owner = subprocess.Popen([executable, "--qualify-native-r2-group" if args.large_group else "--qualify-native-r2-project"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        with selectors.DefaultSelector() as select:
            select.register(owner.stdout, selectors.EVENT_READ)
            require(select.select(700 if args.large_group else 180), "Signed app has not signaled Finder readiness")
            ready = json.loads(owner.stdout.readline())
        require(ready.get("event") == "finder-ready", str(ready))
        source, mount = Path(ready["source"]), Path(ready["mount"])
        work = source.parent
        require(mount == work/"Mount" and work.name.startswith("native-") and source.name == "CloudDrive-"+work.name+("-Group" if args.large_group else ".logicx"), "Wrong fixture identity")
        result["fixture"] = work.name.removeprefix("native-").lower()
        result["nativeReport"] = str(work/"report.json")
        initial = json.loads((work/"report.json").read_text())
        require(native.owned_mount(native.mounts_at(mount), Path(initial["syntheticResourcePath"]), mount), "Wrong native mount")
        allpaths = list(source.rglob("*"))
        contents = {path.relative_to(source): digest(path) for path in allpaths if path.is_file()}
        allowed = {path.relative_to(source) for path in allpaths}
        expected = 765 if args.large_group else 12
        require(len(contents) == expected, "Wrong project shape")
        if not args.large_group:
            require(sum((source/rel).stat().st_size for rel in contents) == 12*32768, "Wrong project payload size")
        targets = [("CloudDrive", mount), ("Helumi", helumi)]
        for label, destination in reversed(targets) if args.helumi_first else targets:
            if label == "Helumi":
                require(helumi_mount() == identity, "Helumi mount changed")
            project = destination/source.name
            copy_started = None
            seeded = args.large_group and label == "CloudDrive"
            if seeded:
                require(project.is_dir() and not project.is_symlink(), "Missing seeded fixture")
                seconds = None
            else:
                require(not project.exists() and not project.is_symlink(), "Generated destination already occupied")
                copy_started = time.time()
                start = time.monotonic()
                applescript = DUPLICATE.replace("150 seconds", "900 seconds") if args.large_group else DUPLICATE
                subprocess.run(["/usr/bin/osascript", "-e", applescript, source, destination], check=True,
                               timeout=915 if args.large_group else 165, stdout=subprocess.DEVNULL)
                seconds = round(time.monotonic() - start, 3)
            def verify_tree(directory):
                require(all((directory/key).is_file() and (args.large_group or digest(directory/key) == value)
                            for key, value in contents.items()), "Finder namespace or bytes differ")
                if args.large_group:
                    for take in source.iterdir():
                        key = take.relative_to(source)/"Clip-0.bin"
                        require(digest(directory/key) == contents[key], "Sample content differs")
            verify_tree(project)
            takes = sorted(p for p in source.iterdir() if p.is_dir())
            require(len(takes) == 12, "Expected twelve folders to group")
            group_seconds = None
            expected_paths = allowed
            if args.large_group:
                require(not (project/"Grouped").exists(), "Destination occupied")
                run_finder(SELECT_FIXTURE, project, *(project/take.name for take in takes))
                start = time.monotonic()
                run_finder(NEW_FOLDER_WITH_SELECTION, project)
                end = start + 180
                names = {t.name for t in takes}
                while True:
                    groups = [d for d in project.iterdir() if d.is_dir() and not d.is_symlink() and d.name not in names
                              and names.issubset({item.name for item in d.iterdir()})]
                    if len(groups) == 1 and all(not (project/t).exists() for t in names):
                        break
                    require(time.monotonic() < end, "Finder grouping did not complete")
                    time.sleep(.05)
                group_seconds = time.monotonic() - start
                run_finder(CLOSE_FIXTURE_WINDOW, project)
                if groups[0].name != "Grouped":
                    groups[0].rename(project/"Grouped")
                require(all(not (project/take.name).exists() for take in takes), "Finder left original folders")
                verify_tree(project/"Grouped")
                expected_paths = {Path("Grouped")} | {Path("Grouped")/key for key in allowed}
            elif label == "CloudDrive" and ready.get("verifyLayout") != "original":
                # Build 40's signed verifier follows each unchanged payload at
                # Grouped/Take-N/Media/audio.bin. Finder treats .logicx as an opaque
                # package; arrange the generated fixture only after its copy/digest
                # measurement. The original source and Helumi copy stay intact.
                grouped = project/"Grouped"
                grouped.mkdir()
                for take in takes:
                    (project/take.name).rename(grouped/take.name)
                verify_tree(grouped)
            result["samples"].append({"drive": label, "copySeconds": seconds, "copyStartedAtUnix": copy_started,
                                      "groupSeconds": round(group_seconds, 3) if group_seconds is not None else None,
                                      "method": "Finder New Folder with Selection" if args.large_group else "Finder duplicate",
                                      "groupedFolders": len(takes) if args.large_group else 0, "descendants": len(allpaths)-len(takes),
                                      "matchedFiles": len(contents), "finderPayloadsHashed": 12,
                                      "appleDoubleFilesAfterCopy": (sum(p.name.startswith("._") for p in project.rglob("*")) if not args.large_group else None)})
            native.save(args.report.with_suffix("." + label + ".progress.json"), result)
            if label == "Helumi":
                tree = list(project.rglob("*"))
                require(all(not p.is_symlink() and (p.relative_to(project) in expected_paths or p.name.startswith("._") or p.name == ".DS_Store") for p in tree),
                        "Unrecognized content in generated comparison directory")
                require(helumi_mount() == identity, "Helumi mount changed before cleanup")
                for path in sorted(tree, key=lambda p: len(p.parts), reverse=True):
                    path.rmdir() if path.is_dir() else path.unlink()
                project.rmdir()
                require(not project.exists(), "Helumi test cleanup failed")
                result["helumiFixtureRemoved"] = True
        with (work/"finder-finished").open("x") as ready_file:
            ready_file.write("verified\n")
            ready_file.flush()
            os.fsync(ready_file.fileno())
        out, _ = owner.communicate(timeout=1500)
        require(owner.returncode == 0, "Managed publication failed: "+out.decode()[-500:])
        proof = json.loads((work/"report.json").read_text())
        require(proof["state"] == "passed" and proof["projectFilesVerified"] == expected and not proof["mountMayRemain"] and not proof["ownerRetained"],
                "Managed readback or safe unmount proof missing")
        result["r2VerifiedFiles"] = proof["projectFilesVerified"]
        result["success"] = True
    finally:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        native.save(args.report, result)
        print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
