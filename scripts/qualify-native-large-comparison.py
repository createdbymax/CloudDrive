#!/usr/bin/env python3
"""Compare identical dense Finder copies on Helumi and an uncapped managed R2 test drive."""

import argparse
import base64
import hashlib
import importlib.util
import json
import os
import plistlib
import selectors
import shutil
import sqlite3
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

script = Path(__file__).with_name("qualify-native-bounded.py")
spec = importlib.util.spec_from_file_location("native", script)
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
q, mounts, require = native.bounded, native.native_mount, native.require
MIB = 1 << 20


def published_file(helper, scratch, volume_id, root_id, expected_name, expected_node, expected_revision):
    """Resolve the filename through R2 HEAD and both verified immutable manifest indexes."""
    selector = scratch / "managed-read-selector"

    def read(key):
        selector.write_text(key)
        data = subprocess.check_output([helper, "read-native-record"], timeout=30)
        require(0 < len(data) <= 256 * 1024, "invalid managed record size")
        if key != "HEAD":
            require(hashlib.sha256(data).hexdigest() == key.split("/")[1], "managed object hash changed")
        return json.loads(data)

    def lookup(root_hash, key):
        branches = hashlib.sha256(key.encode()).hexdigest()
        page_id = root_hash
        for depth in range(65):
            page = read("metadata/" + page_id)
            require(page["version"] == 1 and page["depth"] == depth, "invalid manifest page")
            if not page["children"]:
                return base64.b64decode(page["records"][key], validate=True)
            require(depth < len(branches), "invalid manifest depth")
            page_id = page["children"][branches[depth]]
        raise RuntimeError("manifest lookup exceeded maximum depth")

    head = read("HEAD")
    require(head["version"] in (1, 2) and head["volumeID"] == volume_id, "unexpected R2 HEAD")
    commit = read("commits/" + head["commitID"])
    require(
        commit["volumeID"] == volume_id
        and commit["version"] == head["version"]
        and commit["revision"] == expected_revision,
        "unexpected R2 revision",
    )
    # The generated source name is strictly ASCII, so lower() exactly matches
    # NamespaceStore's normalized case-insensitive lookup for this fixture.
    node_id = lookup(commit["directoryRoot"], root_id + "/" + expected_name.lower()).decode()
    require(node_id == expected_node, "unexpected directory record")
    node = json.loads(lookup(commit["nodeRoot"], node_id))
    require(
        node["id"] == node_id
        and node["name"] == expected_name
        and node["parentID"] == root_id
        and node["size"] == 224 * MIB
        and node.get("deletedRevision") is None,
        "unexpected published node",
    )
    return node["backing"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--interrupt-r2", action="store_true", help="drop only the fixture owner’s R2 connections during the Finder copy")
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    q.local.command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    report = args.report.resolve()
    report.touch(mode=0o600, exist_ok=False)
    root = Path(tempfile.mkdtemp(prefix="clouddrive-finder-comparison-")).resolve()
    result = {
        "success": False,
        "phase": "source",
        "evidence": str(root),
        "samples": [],
        "build": plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleVersion"],
        "engineSHA256": q.sha256(app / "Contents/Resources/CloudDriveEngine"),
    }

    def checkpoint(phase):
        result["phase"] = phase
        tmp = report.with_suffix(".partial")
        tmp.write_text(json.dumps(result, indent=2))
        tmp.replace(report)

    tunnel = None
    if args.interrupt_r2:
        from qualification_r2_tunnel import R2Tunnel
        tunnel = R2Tunnel()
    try:
        source = root / ("CloudDrive-Large-Comparison-" + str(uuid.uuid4()) + ".bin")
        with source.open("xb") as target:
            for _ in range(224):
                target.write(os.urandom(MIB))
        digest = q.sha256(source)
        require(source.stat().st_blocks * 512 >= source.stat().st_size == 224 * MIB, "expected dense source")
        result.update(expectedSHA256=digest, bytes=source.stat().st_size, generatedName=source.name)
        checkpoint("open-native-test-drive")
        binary = app / "Contents/MacOS/CloudDrive"
        owner = subprocess.Popen(
            [binary, "--qualify-native-r2-group"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            env={**os.environ, **({"CLOUDDRIVE_QUALIFICATION_R2_TUNNEL": str(tunnel.port)} if tunnel else {})}
        )
        with selectors.DefaultSelector() as events:
            events.register(owner.stdout, selectors.EVENT_READ)
            require(events.select(700), "seeded fixture timed out")
            ready = json.loads(owner.stdout.readline())
        require(ready.get("event") == "finder-ready", "native fixture setup failed")
        project, mount = Path(ready["source"]), Path(ready["mount"])
        work = project.parent
        ident = str(uuid.UUID(work.name.removeprefix("native-")))
        require(
            work
            == Path.home()
            / "Library/Application Support/BucketDrive/Qualifications"
            / ("native-" + ident.upper())
            and mount == work / "Mount",
            "unknown fixture",
        )
        signed = json.loads((work / "report.json").read_text())
        require(
            mounts.owned_mount(mounts.mounts_at(mount), Path(signed["syntheticResourcePath"]), mount),
            "native mount identity",
        )
        result.update(
            fixture=ident,
            signedReport=str(work / "report.json"),
            availableStateBytes=q.capacity(work / "State")[1],
            stateOnMacSystemDisk=(work.stat().st_dev == Path.home().stat().st_dev),
        )
        require(
            result["stateOnMacSystemDisk"] and result["availableStateBytes"] > source.stat().st_size * 2,
            "normal uncapped state required",
        )
        helumi = Path("/Volumes/Helumi")
        identity = mounts.mounts_at(helumi)
        require(len(identity) == 1 and " (OrbitFS," in identity[0], "Helumi mount unavailable")
        # Both copies use stock Finder. The Helumi result is foreground + mounted readback only.
        for label, destination in [("Helumi", helumi), ("CloudDrive", mount)]:
            dst = destination / source.name
            companion = destination / ("._" + source.name)
            require(
                not os.path.lexists(dst) and not os.path.lexists(companion), "generated destination occupied"
            )
            checkpoint("finder-" + label)
            if tunnel and label == "CloudDrive":
                require(tunnel.forwarded > 0, "fixture never used TLS tunnel")
                tunnel.set_online(False)
            start = time.monotonic()
            start_unix = time.time()
            q.local.command(
                ["/usr/bin/osascript", "-e", q.FINDER, str(source), str(destination)], timeout=1260
            )
            elapsed = time.monotonic() - start
            require(
                dst.is_file()
                and not dst.is_symlink()
                and dst.stat().st_size == source.stat().st_size
                and q.sha256(dst) == digest,
                "mounted content mismatch",
            )
            result["samples"].append(
                {
                    "drive": label,
                    "finderStartedAtUnix": start_unix,
                    "finderSeconds": round(elapsed, 3),
                    "mountedReadbackSHA256": digest,
                }
            )
            if label == "Helumi":
                require(mounts.mounts_at(helumi) == identity, "Helumi changed before cleanup")
                dst.unlink()
                require(
                    not os.path.lexists(dst) and not os.path.lexists(companion), "Helumi cleanup incomplete"
                )
                result["helumiFixtureRemoved"] = True
            else:
                native_start = start
                if tunnel:
                    database = work / "State/Namespace/namespace.sqlite"
                    with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True) as journal:
                        deadline = time.monotonic() + 90
                        while time.monotonic() < deadline:
                            states = journal.execute("select state,error from operations where state != 'complete' order by sequence limit 1").fetchall()
                            if states and states[0][0] == "pending" and states[0][1] in ("offline", "unknownOutcome") and tunnel.refused:
                                break
                            time.sleep(.3)
                        else:
                            raise RuntimeError("no queued operation with confirmed transport outage")
                    result["finderCopyDuringOutage"] = True
                    result["refusedConnections"] = tunnel.refused
                    tunnel.set_online(True)
            checkpoint("verified-" + label)
        # Satisfy this signed fixture's separate startup/readback health check on its generated seed.
        seeded = mount / project.name
        expected = {f"Take-{i}" for i in range(12)}
        require({p.name for p in seeded.iterdir()} == expected, "unexpected test seed")
        grouped = seeded / "Grouped"
        grouped.mkdir()
        for name in sorted(expected):
            (seeded / name).rename(grouped / name)
        (work / "finder-finished").touch(exist_ok=False)
        checkpoint("managed-publication")
        owner.communicate(timeout=1500)
        signed = json.loads((work / "report.json").read_text())
        require(
            owner.returncode == 0
            and signed["state"] == "passed"
            and signed["projectFilesVerified"] == 765
            and not signed["mountMayRemain"]
            and not signed["ownerRetained"]
            and not mounts.mounts_at(mount),
            "native fixture did not complete",
        )
        result["signedPublicationAndUnmountSeconds"] = round(time.monotonic() - native_start, 3)
        checkpoint("independent-large-r2-read")
        db = sqlite3.connect((work / "State/Namespace/namespace.sqlite").as_uri() + "?mode=ro", uri=True)
        try:
            rows = db.execute(
                "select size,backing,id from nodes where deleted is null and name=?", (source.name,)
            ).fetchall()
            revision, published, volume_id, root_id = db.execute(
                "select revision,published,id,root from volume"
            ).fetchone()
            require(
                revision == published and len(rows) == 1 and rows[0][0] == 224 * MIB,
                "missing published native node",
            )
        finally:
            db.close()
        backing = json.loads(rows[0][1])
        key = backing["key"]
        require(
            key.startswith("clouddrive-qualification-" + ident + "/.clouddrive/v1/content/")
            and backing["size"] == 224 * MIB,
            "invalid backing",
        )
        (root / "native-read-key").write_text(key)
        worker = root / "rclone"
        shutil.copy2(app / "Contents/Resources/rclone", worker)
        helper = q.launch(root, worker, ident, q.local.port(), q.local.port(), digest)
        require(
            published_file(helper, root, volume_id, root_id, source.name, rows[0][2], published) == backing,
            "remote manifest locator differs from local",
        )
        result["verifiedRemoteFilename"] = True
        with subprocess.Popen(
            [helper, "read-native-large"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL
        ) as reader:
            checksum = hashlib.sha256()
            count = 0
            while block := reader.stdout.read(MIB):
                checksum.update(block)
                count += len(block)
            require(
                reader.wait(timeout=30) == 0 and count == 224 * MIB and checksum.hexdigest() == digest,
                "large R2 content mismatch",
            )
        result.update(
            r2SHA256=checksum.hexdigest(), verifiedSeconds=round(time.monotonic() - native_start, 3)
        )
        checkpoint("verified-r2-cleanup")
        keys = q.inventory(helper, "files")
        require(len(keys) >= 3, "missing test objects")
        q.local.command([helper, "clean-native-managed"], timeout=1500)
        require(not q.inventory(helper, "files") and not q.inventory(helper, "stages"), "test objects remain")
        result.update(remainingKeys=0, generatedKeysRemoved=len(keys), success=True)
        del result["evidence"]
        checkpoint("complete")
        shutil.rmtree(root)
    except Exception as error:
        result.update(error=type(error).__name__, reason=str(error)[:400])
        checkpoint(result["phase"])
        raise
    finally:
        if tunnel:
            tunnel.close()


if __name__ == "__main__":
    main()
