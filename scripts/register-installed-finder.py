#!/usr/bin/env python3
"""Keep a just-installed development FSKit extension from competing with build products."""
import argparse
from pathlib import Path
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parents[1]
APP = Path("/Applications/CloudDrive.app")
LS = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
PLUGIN = "local.bucketdrive.app.filesystem"


def checked(*args):
    return subprocess.run(args, capture_output=True, check=True, text=True).stdout


def signed(app):
    checked("codesign", "--verify", "--deep", "--strict", app)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "local.bucketdrive.app":
        raise SystemExit(f"Different app: {app}")
    extension = app / "Contents/Extensions/CloudDriveFS.appex"
    if plistlib.loads((extension / "Contents/Info.plist").read_bytes()).get("CFBundleIdentifier") != PLUGIN:
        raise SystemExit(f"Different filesystem extension: {extension}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--retire-build", action="append", default=[], type=Path,
                        help="Inactive CloudDrive.app inside this checkout's build directory; repeat as needed")
    args = parser.parse_args()
    signed(APP)
    if " (clouddrive," in checked("/sbin/mount"):
        raise SystemExit("Eject CloudDrive volumes normally before changing extension registrations.")
    running = checked("ps", "-axo", "comm=").splitlines()
    builds = []
    for path in args.retire_build:
        path = path.resolve(strict=True)
        dest = path.with_name("CloudDrive-qualified-bundle")
        if path.name != "CloudDrive.app" or ROOT / "build" not in path.parents or dest.exists():
            raise SystemExit(f"Not an eligible build product: {path}")
        if any(line.strip().startswith(str(path) + "/") for line in running):
            raise SystemExit(f"Build still running: {path}")
        signed(path)
        builds.append((path, dest))
    for path, dest in builds:
        for extension in (path / "Contents").rglob("*.appex"):
            subprocess.run(["pluginkit", "-r", extension], capture_output=True)
        checked(LS, "-u", path)
        path.rename(dest)  # Retain signed bytes without advertising another app to Launch Services.
    checked(LS, "-f", APP)
    for extension in (APP / "Contents").rglob("*.appex"):
        checked("pluginkit", "-a", extension)
    paths = [line.split("Path = ", 1)[1] for line in checked("pluginkit", "-mAvv", "-i", PLUGIN).splitlines() if "Path = " in line]
    if paths != [str(APP / "Contents/Extensions/CloudDriveFS.appex")]:
        raise SystemExit("The installed filesystem extension is not the sole registered path.")
    print("The installed CloudDrive filesystem extension is registered.")


if __name__ == "__main__":
    main()
