#!/usr/bin/env python3
"""Copy 224 MiB in Finder using a worker confined to a 160 MiB APFS cache.

--r2 uses the app's existing stable signer and read-only, noninteractive Keychain
access. The compiled launcher pins one worker hash, two ports, one cache path and
one fresh bucket-root sibling prefix. No installation or owner mount is involved.
--image-only verifies the hard cap without Keychain, network, or a running worker.
A failed run retains private state for diagnosis or resumption.
"""
import argparse
import base64
import hashlib
import importlib.util
import json
import os
import pathlib
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import uuid

import signing

SCRIPTS = pathlib.Path(__file__).resolve().parent
MIB = 1024 * 1024
IMAGE_MIB, PAYLOAD_MIB = 160, 224
MARKER = "owner-v1"
FINDER = '''on run argv
set src to (POSIX file (item 1 of argv)) as alias
set dst to (POSIX file (item 2 of argv)) as alias
with timeout of 1800 seconds
tell application "Finder" to duplicate src to dst
end timeout
end run'''
spec = importlib.util.spec_from_file_location("local", SCRIPTS / "qualify-local.py")
local = importlib.util.module_from_spec(spec)
spec.loader.exec_module(local)


def require(condition, reason):
    if not condition:
        raise RuntimeError(reason)


def sha256(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def capacity(path):
    stat = os.statvfs(path)
    return stat.f_blocks * stat.f_frsize, stat.f_bavail * stat.f_frsize


def launch(root, binary, uid, nfs, rc, verified_source_sha=""):
    values = {"root": str(root), "id": uid, "worker": str(binary), "sha": sha256(binary),
              "nfs": str(nfs), "rc": str(rc), "marker": MARKER, "verifiedSourceSHA":verified_source_sha}
    # Escape arbitrary path bytes as base64, never interpolate them into Swift source.
    fields = []
    for key, value in values.items():
        encoded = base64.b64encode(value.encode()).decode()
        fields.append(f'    static let {key} = String(data: Data(base64Encoded: "{encoded}")!, encoding: .utf8)!')
    pinned = root / "Pinned.swift"
    pinned.write_text("import Foundation\nenum Pinned {\n" + "\n".join(fields) + "\n}\n")
    helper = root / "fixture-runner"
    local.command(["/usr/bin/swiftc", str(SCRIPTS/"fixtures/bounded-r2-launcher.swift"), str(pinned),
                   "-o", str(helper)], timeout=120)
    signer = signing.selection()
    require(signer != "-", "stable signing identity required")
    signing.sign_target(helper, signing.APP_ID, signer)
    installed = pathlib.Path("/Applications/CloudDrive.app")
    designated = signing.designated_requirement(signing.run(["/usr/bin/codesign", "-d", "-r-", str(installed)]))
    signing.validate_stable_requirement(designated)
    signing.run(["/usr/bin/codesign", "--verify", "--strict", "--test-requirement", "="+designated, str(helper)])
    return helper


def inventory(helper, scope):
    process = subprocess.run([helper, scope], capture_output=True, timeout=45)
    if process.returncode == 3:  # Rclone's documented directory-not-found exit.
        return []
    require(process.returncode == 0, "provider inventory failed")
    entries = json.loads(process.stdout)
    require(isinstance(entries, list), "provider inventory invalid")
    return [(entry["Path"], entry["Size"]) for entry in entries if not entry["IsDir"]]


def clean_retained(report_path, binary):
    report = json.loads(report_path.read_text())
    uid = str(uuid.UUID(report["fixture"]))
    root = pathlib.Path(report["fixtureDirectory"]).resolve(strict=True)
    temp_root = pathlib.Path(tempfile.gettempdir()).resolve(strict=True)
    require(root.parent == temp_root and root.name.startswith("clouddrive-bounded-"+uid+"-")
            and root.stat().st_uid == os.getuid() and root.stat().st_mode & 0o077 == 0, "unexpected fixture directory")
    require(report["cacheDetached"] is True and report["phase"]=="verified-generated-object-cleanup"
            and not local.is_mounted(root/"finder-volume") and not local.is_mounted(root/"cache-volume"), "fixture still live")
    require(report["providerSHA256"] == report["sourceSHA256"] == sha256(root/"finder-payload.bin"), "verified source proof missing")
    mounts = local.command(["/sbin/mount"])
    require(" on "+str(root)+"/" not in mounts, "another mount exists inside fixture")
    active_commands = local.command(["/bin/ps","-axo","comm="])
    for row in active_commands.splitlines():
        command = pathlib.Path(row.strip())
        if command.name in ("pinned-worker","fixture-runner"):
            require(command.resolve().parent != root, "fixture process remains live")
    helper = launch(root,binary.resolve(strict=True),uid,local.port(),local.port(),report["providerSHA256"])
    if inventory(helper,"files"):
        local.command([str(helper),"clean-finder-companions"],timeout=120)
    before = inventory(helper,"stages")
    if before:
        local.command([str(helper),"clean-proven-orphans"],timeout=1200)
        require([name for name,_ in inventory(helper,"stages")] == [MARKER], "unexpected private inventory")
        local.command([str(helper),"clean-marker"],timeout=60)
    require(not inventory(helper,"files") and not inventory(helper,"stages"), "generated remote fixtures remain")
    cleanup = {"visibleFiles":0,"privateStageFiles":0,"removedStageEntries":len(before),"fixture":uid}
    result = report_path.with_name(report_path.stem+"-cleanup.json")
    with result.open("x") as out: json.dump(cleanup,out,indent=2)
    shutil.rmtree(root)
    print(json.dumps(cleanup),flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--image-only", action="store_true")
    mode.add_argument("--r2", action="store_true")
    mode.add_argument("--cleanup-retained", action="store_true",
                      help="clean verified spill orphans from one failed post-publication report")
    parser.add_argument("--worker", type=pathlib.Path)
    parser.add_argument("--case", choices=("finder","recovery","recovery-without-move"), default="finder",
                        help="Finder copy or open-handle edits followed by deliberate isolated worker death")
    parser.add_argument("--check-cold-edit", action="store_true", help="also edit an evicted, previously published object after recovery")
    parser.add_argument("--report", type=pathlib.Path, required=True)
    args = parser.parse_args()
    if args.check_cold_edit and (not args.r2 or args.case != "recovery"):
        parser.error("--check-cold-edit requires --r2 --case recovery")
    if (args.r2 or args.cleanup_retained) and not args.worker:
        parser.error("--r2 requires --worker")
    report_path = args.report.resolve()
    if args.cleanup_retained:
        clean_retained(report_path,args.worker)
        return
    require(not report_path.exists(), "use a fresh report path")
    report_path.parent.mkdir(exist_ok=True, parents=True)
    uid = str(uuid.uuid4())
    root = pathlib.Path(tempfile.mkdtemp(prefix="clouddrive-bounded-"+uid+"-")).resolve()
    root.chmod(0o700)
    volume, mount = root/"cache-volume", root/"finder-volume"
    volume.mkdir()
    mount.mkdir()
    image = root/"cache.sparseimage"
    report = {"fixture": uid, "case": args.case, "scope": "APFS-cap" if args.image_only else "Finder/APFS/R2",
              "fixtureDirectory": str(root), "success": False}
    def checkpoint(phase):
        report["phase"] = phase
        temporary = root/"report.tmp"
        temporary.write_text(json.dumps(report, indent=2)+"\n")
        # Root and requested report can live on different filesystems.
        shutil.copyfile(temporary, report_path)
    worker = None
    attached = False
    device = None
    stop = threading.Event()
    observer = None
    passed = False
    try:
        checkpoint("create-capped-volume")
        local.command(["/usr/bin/hdiutil", "create", "-size", f"{IMAGE_MIB}m", "-fs", "APFS",
                       "-type", "SPARSE", "-volname", "CloudDrive-Cache-Test", str(image)], timeout=90)
        attached_data = plistlib.loads(subprocess.check_output(["/usr/bin/hdiutil","attach",str(image),"-nobrowse",
            "-mountpoint",str(volume),"-plist"],stderr=subprocess.DEVNULL, timeout=60))
        attached = True
        device = next(e["dev-entry"] for e in attached_data["system-entities"] if e.get("mount-point")==str(volume))
        info = plistlib.loads(subprocess.check_output(["/usr/sbin/diskutil","info","-plist",str(volume)],timeout=20))
        total, start_free = capacity(volume)
        require(info["FilesystemType"] == "apfs" and info["DeviceNode"] == device and volume.stat().st_dev != root.stat().st_dev,
                "cache mount identity mismatch")
        require(64*MIB < start_free <= total <= IMAGE_MIB*MIB < PAYLOAD_MIB*MIB, "image hard-cap mismatch")
        report.update(hardCapacityBytes=total, initialAvailableBytes=start_free, payloadBytes=PAYLOAD_MIB*MIB)
        if args.image_only:
            passed = True
            return
        candidate = args.worker.resolve(strict=True)
        binary = root/"pinned-worker"
        shutil.copy2(candidate,binary)
        require(sha256(candidate)==sha256(binary), "candidate changed during fixture staging")
        require("--vfs-spill-prefix" in local.command([str(binary),"serve","nfs","--help"]), "worker lacks spill flags")
        nfs, rc = local.port(), local.port()
        while nfs == rc: rc = local.port()
        token = os.urandom(32).hex()
        checkpoint("pin-and-sign-one-use-launcher")
        helper = launch(root, binary, uid, nfs, rc)
        report["workerSHA256"] = sha256(binary)
        checkpoint("preflight-generated-provider-prefixes")
        require(not inventory(helper, "files") and not inventory(helper, "stages"), "new generated prefix occupied")
        (volume/"cache").mkdir()
        (volume/"temp").mkdir()
        payload = root/"finder-payload.bin"
        with payload.open("xb") as handle:
            for _ in range(PAYLOAD_MIB if args.case=="finder" else 80): handle.write(os.urandom(MIB))
        report["payloadBytes"] = payload.stat().st_size
        expected = sha256(payload)
        report["sourceSHA256"] = expected
        auth = "Basic "+base64.b64encode(("fixture:"+token).encode()).decode()
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        def call(route, parameters=None):
            request = urllib.request.Request(f"http://127.0.0.1:{rc}/{route}",data=json.dumps(parameters or {}).encode(),
                headers={"Content-Type":"application/json","Authorization":auth})
            with opener.open(request,timeout=5) as response: return json.load(response)
        checkpoint("start-isolated-worker")
        def online():
            require(worker.poll() is None, "fixture worker exited")
            return call("vfs/stats")
        def start_worker():
            nonlocal worker
            require(worker is None or worker.poll() is not None, "previous fixture worker still running")
            task = "serve" if args.case == "finder" else "serve-held"
            with (root/"worker-categories.txt").open("ab") as messages:
                worker = subprocess.Popen([helper, task], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=messages)
            worker.stdin.write((token+"\n").encode())
            worker.stdin.close()
            recovery = root/"control.json"
            recovery.touch(mode=0o600)
            recovery.write_text(json.dumps({"pid":worker.pid,"rcPort":rc,"nfsPort":nfs,"token":token,"cacheDevice":device}))
            local.until(online, seconds=35)
            stats = online()
            require(stats["fs"].rstrip("/").endswith("/clouddrive-qualification-"+uid), "fixture binding mismatch")
            cache_path = pathlib.Path(stats["diskCache"]["path"]).resolve()
            require(volume/"cache" in cache_path.parents, "worker cache outside cap")
            return cache_path
        def mount_fixture():
            require(not local.is_mounted(mount), "fixture already mounted")
            local.command(["/sbin/mount_nfs","-o",f"port={nfs},mountport={nfs},tcp,vers=3,nolocks,mutejukebox,nodev,nosuid,rsize=262144,wsize=262144,acregmin=0,acregmax=1","127.0.0.1:/",str(mount)])
            require(local.is_mounted(mount), "NFS mount absent")
        cache_path = start_worker()
        checkpoint("mount-generated-finder-volume")
        mount_fixture()
        def observe():
            while not stop.is_set():
                available = capacity(volume)[1]
                report["peakVolumeUseBytes"] = max(report.get("peakVolumeUseBytes",0), start_free-available)
                stop.wait(.1)
        observer = threading.Thread(target=observe,daemon=True)
        observer.start()
        start = time.monotonic()
        if args.case == "finder":
            checkpoint("finder-duplicate")
            cp = subprocess.run(["/usr/bin/osascript","-e",FINDER,str(payload),str(mount)],capture_output=True,timeout=1810)
            require(cp.returncode == 0, "Finder duplicate failed")
            report["finderSeconds"] = round(time.monotonic()-start,3)
        else:
            checkpoint("stage-and-open-handle-mutation")
            io = subprocess.Popen([sys.executable,SCRIPTS/"fixtures/bounded-recovery-io.py",root],
                stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            try:
                def initial_synced():
                    require(io.poll() is None, "initial NFS write failed")
                    return (root/"synced-initial-payload").is_file()
                local.until(initial_synced,seconds=600)
                def punched_and_backed():
                    chunks = [name for name,_ in inventory(helper,"stages") if name != MARKER]
                    cache_file = (cache_path/"finder-payload.bin").stat()
                    if chunks and cache_file.st_blocks*512+4*MIB <= payload.stat().st_size:
                        report["preMutationChunkCount"] = len(chunks)
                        report["preMutationCacheBytes"] = cache_file.st_blocks*512
                        return True
                    return False
                local.until(punched_and_backed,seconds=180)
                if args.case == "recovery":
                    reply = call("vfs/move", {"source":"finder-payload.bin","destination":"busy-rename.bin","requestID":str(uuid.uuid4())})
                    if reply.get("accepted") is True:
                        def refused_after_admission():
                            jobs = call("vfs/moves")["jobs"]
                            matches = [job for job in jobs if job["id"]==reply["id"] and not job["active"]]
                            if not matches: return False
                            job = matches[0]
                            require(not job["needsRecovery"] and "busy" in job["message"].lower(), "active rename unexpectedly completed or failed ambiguously")
                            return True
                        local.until(refused_after_admission,seconds=30)
                    else:
                        require(reply.get("reason")=="busy", "active rename lacked busy refusal")
                    report["openDirtyRename"] = "busy; source retained"
                (root/"allow-mutation").touch()
                require(io.wait(timeout=600) == 0, "open rename, overlap, truncate/regrow or checksum failed")
            finally:
                if io.poll() is None:
                    io.kill()
                    io.wait(timeout=5)
            expected = sha256(payload)
            report["sourceSHA256"] = expected
            report["finalBytes"] = payload.stat().st_size
            checkpoint("crash-pending-fixture-worker")
            require(not any(name=="finder-payload.bin" for name,_ in inventory(helper,"files")), "unexpected published file before crash")
            local.command(["/sbin/umount",str(mount)],timeout=30)
            require(not local.is_mounted(mount), "fixture still mounted before crash")
            target = call("core/pid")["pid"]
            actual = local.command(["/bin/ps","-p",str(target),"-o","ppid=,comm="]).strip().split(maxsplit=1)
            require(int(actual[0]) == worker.pid and pathlib.Path(actual[1]).resolve() == binary, "crash target identity mismatch")
            os.kill(target,signal.SIGKILL)
            require(worker.wait(timeout=10) != 0, "fixture crash not observed")
            checkpoint("restart-and-read-unpublished-bytes")
            start_worker()
            mount_fixture()
            require(not any(name=="finder-payload.bin" for name,_ in inventory(helper,"files")), "postrestart read would use fully published cloud file")
            recovered = local.command([sys.executable,"-c",
                "import hashlib,sys; print(hashlib.file_digest(open(sys.argv[1],'rb'),'sha256').hexdigest())",
                str(mount/"finder-payload.bin")],timeout=600).strip()
            require(recovered == expected, "restarted punched-range checksum mismatch")
            report["recoveredSHA256"] = recovered
            queue = call("vfs/queue")["queue"]
            queued = [entry for entry in queue if entry["name"]=="finder-payload.bin"]
            require(len(queued)==1 and not queued[0]["uploading"], "pending recovered file unavailable")
            for entry in queue:
                require(entry["name"] in ("finder-payload.bin","._finder-payload.bin",".DS_Store","._.DS_Store"),
                        "unexpected item in isolated recovery queue")
                if not entry["uploading"]:
                    call("vfs/queue-set-expiry", {"id":entry["id"],"expiry":-1000000000})
        checkpoint("wait-for-publication")
        def published():
            cache = online()["diskCache"]
            require(cache["erroredFiles"] == 0 and not cache["outOfSpace"], "cache error after Finder copy")
            return cache["uploadsInProgress"] == cache["uploadsQueued"] == 0 and ("finder-payload.bin",payload.stat().st_size) in inventory(helper,"files")
        local.until(published,seconds=1800)
        checkpoint("independent-provider-sha256")
        def download_checksum():
            # Fresh process, direct S3 GET. Hash the stream without allocating a second full file.
            reader = subprocess.Popen([helper,"read"],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
            checksum = subprocess.Popen([sys.executable,"-c",
                "import hashlib,sys; print(hashlib.file_digest(sys.stdin.buffer, 'sha256').hexdigest())"],
                stdin=reader.stdout,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
            reader.stdout.close()
            try:
                digest_output, _ = checksum.communicate(timeout=900)
                require(checksum.returncode == 0 and reader.wait(timeout=10) == 0, "independent provider GET failed")
                observed = digest_output.decode("ascii").strip()
            finally:
                for process in (checksum, reader):
                    if process.poll() is None:
                        process.kill()
                        process.wait(timeout=5)
            return observed
        observed = download_checksum()
        report["providerSHA256"] = observed
        require(observed == expected, "provider checksum mismatch")
        report["publicationVerifiedSeconds"] = round(time.monotonic()-start,3)
        if args.check_cold_edit:
            report["preColdEditProviderSHA256"] = observed
            checkpoint("confirm-base-evicted")
            # The subsequent write must pull missing original bytes from R2.
            local.until(lambda: not (cache_path/"finder-payload.bin").exists(), seconds=90)
            local.command(["/sbin/umount", str(mount)], timeout=30)
            require(not local.is_mounted(mount), "fixture still mounted before cold edit")
            mount_fixture()
            checkpoint("edit-remote-base")
            edit_script = """
import os, sys
with open(sys.argv[1], "r+b", buffering=0) as item:
    item.seek(4*1024*1024-3)
    item.write(b'cold-edit-across-two-pages')
    item.seek(8193, os.SEEK_END)
    item.write(b'cold-sparse-append')
    os.fsync(item.fileno())
"""
            for target_path in (mount/"finder-payload.bin", payload):
                local.command([sys.executable,"-c",edit_script,str(target_path)],timeout=900)
            expected = sha256(payload)
            queue = call("vfs/queue")["queue"]
            queued = [entry for entry in queue if entry["name"] == "finder-payload.bin" and not entry["uploading"]]
            require(len(queued) == 1, "cold edit not in held upload queue")
            call("vfs/queue-set-expiry", {"id":queued[0]["id"],"expiry":-1000000000})
            local.until(published, seconds=1800)
            observed = download_checksum()
            require(observed == expected, "edited remote base checksum mismatch")
            report.update(coldEditAfterEviction=True, sourceSHA256=expected, providerSHA256=observed,
                          finalBytes=payload.stat().st_size)
        checkpoint("normal-unmount")
        local.command(["/sbin/umount",str(mount)],timeout=30)
        require(not local.is_mounted(mount), "fixture still mounted")
        call("core/quit")
        require(worker.wait(timeout=20)==0, "worker did not exit normally")
        checkpoint("verified-generated-object-cleanup")
        files = inventory(helper,"files")
        require(("finder-payload.bin",payload.stat().st_size) in files, "verified fixture disappeared")
        local.command([str(helper),"clean-payload"],timeout=40)
        if inventory(helper,"files"):
            local.command([str(helper),"clean-finder-companions"],timeout=90)
        report["retainedFixtureFileCount"] = len(inventory(helper, "files"))
        require(report["retainedFixtureFileCount"] == 0, "fixture still contains objects")
        stages = inventory(helper,"stages")
        report["retainedStageFileCount"] = len(stages)
        # Unknown stage objects are never guessed or removed.
        if len(stages)==1 and stages[0][0]==MARKER:
            local.command([str(helper),"clean-marker"],timeout=40)
            report["retainedStageFileCount"] = len(inventory(helper,"stages"))
        require(report["retainedStageFileCount"] == 0, "spill chunks or marker survived publication")
        passed = True
    except Exception as error:
        report["failureKind"] = type(error).__name__
        if type(error) is RuntimeError: report["reason"] = str(error)
    finally:
        stop.set()
        if observer: observer.join(timeout=2)
        # On failure preserve a still-running worker and its cache. Normal teardown only.
        detached = False
        if attached and (worker is None or worker.poll() is not None) and not local.is_mounted(mount):
            try:
                local.command(["/usr/bin/hdiutil","detach",device],timeout=30)
                detached = not local.is_mounted(volume)
            except Exception: pass
        categories = root/"worker-categories.txt"
        if categories.exists():
            from collections import Counter
            allowed = {"provider-not-implemented","provider-501","spill-cleanup-retained","verification",
                       "checksum-mismatch","no-space","worker-error"}
            report["workerDiagnosticCounts"] = dict(Counter(line for line in categories.read_text().splitlines() if line in allowed))
        report["cacheDetached"] = detached
        report["success"] = passed and detached
        if report["success"]:
            report.pop("fixtureDirectory",None)
            checkpoint("complete")
            shutil.rmtree(root)
        else: checkpoint(report.get("phase","setup"))
        print(json.dumps(report),flush=True)
        if not report["success"]: sys.exit(1)


if __name__ == "__main__": main()
