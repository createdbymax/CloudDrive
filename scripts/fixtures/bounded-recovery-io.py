#!/usr/bin/env python3
"""Child for blocking NFS I/O. Owns only generated names in the supplied fixture."""
import os
from pathlib import Path
import shutil
import sys
import time

MIB = 1024*1024


def edit(handle):
    handle.seek(4*MIB-37)
    handle.write(b"overlapping-two-extents"*4096)
    handle.truncate(60*MIB+117)
    handle.truncate(72*MIB+41)
    handle.seek(-41,os.SEEK_END)
    handle.write(b"z"*41)
    handle.flush()
    os.fsync(handle.fileno())


def run(root):
    source = root/"finder-payload.bin"
    mount = root/"finder-volume"
    final = mount/"finder-payload.bin"
    require_file = root/"allow-mutation"
    with final.open("xb+") as handle, source.open("rb") as fixture:
        shutil.copyfileobj(fixture,handle,MIB)
        handle.flush()
        os.fsync(handle.fileno())
        (root/"synced-initial-payload").touch()
        deadline = time.monotonic()+300
        while not require_file.exists():
            if time.monotonic()>deadline: raise RuntimeError("stage verification timed out")
            time.sleep(.2)
        # Parent submitted a protected rename while this original descriptor was open.
        if (mount/"busy-rename.bin").exists(): raise RuntimeError("active rename replaced source")
        edit(handle)
    with source.open("r+b") as oracle: edit(oracle)
    with final.open("rb") as mounted, source.open("rb") as local:
        # Exercise original, overlapping, truncated and regrown ranges before the crash.
        # The separate cold-remount and provider reads both hash the entire file.
        for offset in (0,4*MIB-64,12*MIB,60*MIB-64,64*MIB,72*MIB-128):
            local.seek(offset)
            mounted.seek(offset)
            if local.read(256) != mounted.read(256): raise RuntimeError("pre-crash range mismatch")


if __name__ == "__main__": run(Path(sys.argv[1]))
