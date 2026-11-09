#!/usr/bin/env python3
"""Verify a 224 MiB dense Finder copy against live managed R2 on a 160 MiB APFS state volume."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import threading
import time
import uuid

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("bounded", HERE / "qualify-bounded-finder.py")
bounded = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bounded)
native_spec = importlib.util.spec_from_file_location("native_mount", HERE / "qualify-fskit-mounted.py")
native_mount = importlib.util.module_from_spec(native_spec)
native_spec.loader.exec_module(native_mount)
local = bounded.local
require = bounded.require
MIB = 1 << 20


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="Signed candidate CloudDrive.app")
    parser.add_argument("--report", type=Path, required=True, help="Write a fresh qualification report")
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    binary = app / "Contents/MacOS/CloudDrive"
    engine = app / "Contents/Resources/CloudDriveEngine"
    rclone = app / "Contents/Resources/rclone"
    local.command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    with (app / "Contents/Info.plist").open("rb") as info_file:
        build = plistlib.load(info_file)["CFBundleVersion"]
    report_path = args.report.resolve()
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.touch(exist_ok=False, mode=0o600)
    ident = str(uuid.uuid4())
    qualifications = Path.home() / "Library/Application Support/BucketDrive/Qualifications"
    require(qualifications.resolve() == qualifications and qualifications.is_dir(), "missing private qualification folder")
    root = qualifications / ("Bounded-" + ident)
    root.mkdir(mode=0o700)
    volume = root / "CacheVolume"
    volume.mkdir(mode=0o700)
    source = root / "finder-payload.bin"
    report = {"fixtureID": ident, "fixtureDirectory": str(root), "scope": "real Finder, mounted FSKit and managed R2",
              "success": False, "appBuild": build, "engineSHA256": bounded.sha256(engine)}
    stop = threading.Event()
    observer = None

    def checkpoint(phase):
        report["phase"] = phase
        temporary = report_path.with_suffix(".partial")
        temporary.write_text(json.dumps(report, indent=2) + "\n")
        temporary.replace(report_path)

    try:
        checkpoint("create-capped-volume")
        image = root / "state.sparseimage"
        local.command(["/usr/bin/hdiutil", "create", "-size", "160m", "-fs", "APFS", "-type", "SPARSE", "-volname", "CloudDrive-Native-Test", str(image)], timeout=90)
        result = plistlib.loads(subprocess.check_output(["/usr/bin/hdiutil", "attach", str(image), "-nobrowse", "-mountpoint", str(volume), "-plist"], timeout=60))
        device = next(row["dev-entry"] for row in result["system-entities"] if row.get("mount-point") == str(volume))
        info = plistlib.loads(subprocess.check_output(["/usr/sbin/diskutil", "info", "-plist", str(volume)], timeout=30))
        total, initial_free = bounded.capacity(volume)
        require(info["DeviceNode"] == device and info["FilesystemType"] == "apfs" and volume.stat().st_dev != root.stat().st_dev and 64*MIB < initial_free <= total <= 160*MIB, "fixture APFS capacity mismatch")
        digest = hashlib.sha256()
        with source.open("xb") as output:
            for _ in range(224):
                block = os.urandom(MIB)
                output.write(block)
                digest.update(block)
        expected = digest.hexdigest()
        require(source.stat().st_size == 224*MIB and source.stat().st_blocks*512 >= source.stat().st_size, "dense source required")
        (root / "source.sha256").write_text(expected)
        report.update(sourceSHA256=expected, payloadBytes=source.stat().st_size, hardCapacityBytes=total, initialAvailableBytes=initial_free)
        checkpoint("start-isolated-native-diagnostic")
        env = dict(os.environ, CLOUDDRIVE_BOUNDED_FIXTURE_ID=ident)

        def sample():
            next_breakdown = time.monotonic()
            while not stop.wait(.1):
                consumed = initial_free - bounded.capacity(volume)[1]
                report["peakVolumeUseBytes"] = max(report.get("peakVolumeUseBytes", 0), consumed)
                if time.monotonic() < next_breakdown:
                    continue
                next_breakdown = time.monotonic() + 3
                stats = report.setdefault("peakContentFiles", {})
                for name in ("snapshots", "extents", "writeback"):
                    files = volume / "State" / "Content" / name
                    try:
                        count = len(os.listdir(files))
                        stats[name] = max(stats.get(name, 0), count)
                    except FileNotFoundError:
                        pass

        observer = threading.Thread(target=sample, daemon=True)
        observer.start()
        with (root/"diagnostic.jsonl").open("xb") as output, (root/"diagnostic.stderr").open("xb") as errors:
            diagnostic = subprocess.Popen([binary, "--qualify-native-r2-bounded"], env=env, stdout=output, stderr=errors)
            def mounted():
                require(diagnostic.poll() is None, "native diagnostic exited before Finder mount")
                return (root / "ready.json").exists()
            local.until(mounted, seconds=180)
            locations = json.loads((root/"ready.json").read_text())
            work, mount = Path(locations["work"]), Path(locations["mount"])
            run_id = str(uuid.UUID(work.name.removeprefix("native-")))
            require(work.parent == qualifications and mount == work/"Mount" and work.resolve() == work, "native fixture identity mismatch")
            state = json.loads((work/"report.json").read_text())
            resource = state["syntheticResourcePath"]
            require(native_mount.owned_mount(native_mount.mounts_at(mount), Path(resource), mount), "wrong native mount")
            report.update(nativeRunID=run_id, nativeWorkDirectory=str(work))
            report["finderStartedAtUnix"] = time.time()
            checkpoint("finder-duplicate")
            start = time.monotonic()
            finder = subprocess.run(["/usr/bin/osascript", "-e", bounded.FINDER, str(source), str(mount)], capture_output=True, timeout=1260)
            if finder.returncode:
                (root / "finder-failed").touch(exist_ok=False)
                code = re.search(rb"\((-?[0-9]+)\)\s*$", finder.stderr)
                if code:
                    report["finderErrorNumber"] = int(code[1])
                st = os.statvfs(mount)
                report["reportedAvailableBytes"] = st.f_bavail * st.f_frsize
                raise RuntimeError("Finder copy failed")
            report["finderSeconds"] = round(time.monotonic()-start, 3)
            (root/"finder-copied").touch(exist_ok=False)
            checkpoint("native-publication-and-independent-r2-hash")
            code = diagnostic.wait(timeout=1700)
            state = json.loads((work/"report.json").read_text())
            report.update(nativeState=state["state"], nativeStage=state["stage"], diagnostic=state.get("diagnostic"))
            require(state.get("sha256") == expected, "managed R2 readback did not match the source")
            report["r2SHA256"] = state["sha256"]
            report["verifiedSeconds"] = round(time.monotonic()-start, 3)
            require(code == 0 and state["state"] == "passed", "signed diagnostic failed at " + state["stage"])
            require(not state["ownerRetained"] and not state["mountMayRemain"] and not local.is_mounted(mount), "native owner or mounted volume retained")
        stop.set()
        observer.join(timeout=2)
        require(0 < report["peakVolumeUseBytes"] <= total < source.stat().st_size, "missing capped-volume observation")
        checkpoint("verified-generated-object-cleanup")
        helper = bounded.launch(root, rclone, run_id, local.port(), local.port(), expected)
        before = bounded.inventory(helper, "files")
        require(len(before) >= 3, "managed qualification objects missing")
        local.command([str(helper), "clean-native-managed"], timeout=900)
        require(not bounded.inventory(helper, "files") and not bounded.inventory(helper, "stages"), "generated qualification objects remain")
        report.update(generatedKeysRemoved=len(before), remainingKeys=0)
        require(not local.is_mounted(mount) and local.is_mounted(volume), "unexpected final mount state")
        local.command(["/usr/bin/hdiutil", "detach", device], timeout=60)
        require(not local.is_mounted(volume), "cache image still attached")
        report.update(cacheDetached=True, success=True)
        report.pop("fixtureDirectory")
        checkpoint("complete")
        shutil.rmtree(root)
    except Exception as error:
        report.update(failureKind=type(error).__name__, reason=str(error) if isinstance(error, RuntimeError) else "diagnostics retained")
        checkpoint(report["phase"])
    finally:
        stop.set()
        if observer:
            observer.join(timeout=2)
    print(json.dumps(report))
    return 0 if report["success"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
