#!/usr/bin/env python3
"""P4 feasibility probe: does --backup-dir preserve NFS deletions/replacements?

Generated local files only. This measures a candidate flag, not a recovery feature.
No owner credentials, cache or drive are accessed. Failure fixtures are retained.
"""
import argparse
import base64
import hashlib
import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('qualification', ROOT/'scripts/qualify-local.py')
local = importlib.util.module_from_spec(spec)
spec.loader.exec_module(local)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rclone', type=pathlib.Path, default=ROOT/'build/backend/rclone')
    binary = parser.parse_args().rclone.resolve(strict=True)
    root = pathlib.Path(tempfile.mkdtemp(prefix='clouddrive-preservation-')).resolve()
    root.chmod(0o700)
    source, mount, history = (root/name for name in ('source', 'mount', 'history'))
    for path in (source, mount, history): path.mkdir()
    originals = {name: os.urandom(65536) for name in ('delete.bin', 'overwrite.bin', 'replace.bin')}
    for name, data in originals.items(): (source/name).write_bytes(data)
    nfs, rc = local.port(), local.port()
    while nfs == rc: rc = local.port()
    token = os.urandom(32).hex()
    env = {key: os.environ[key] for key in ('PATH', 'HOME', 'TMPDIR', 'LANG') if key in os.environ}
    env.update(RCLONE_RC_USER='fixture', RCLONE_RC_PASS=token)
    log = (root/'worker.log').open('wb')
    worker = subprocess.Popen([str(binary), 'serve', 'nfs', str(source),
        '--config', '/dev/null', '--addr', f'127.0.0.1:{nfs}', '--cache-dir', str(root/'cache'),
        '--vfs-cache-mode', 'full', '--vfs-write-back', '1s', '--backup-dir', str(history),
        '--rc', '--rc-addr', f'127.0.0.1:{rc}'], env=env, stdout=log, stderr=log)
    fd = os.open(root/'fixture-control.json', os.O_CREAT|os.O_EXCL|os.O_WRONLY, 0o600)
    with os.fdopen(fd, 'w') as handle:
        json.dump({'pid': worker.pid, 'controlPort': rc, 'nfsPort': nfs, 'token': token}, handle)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def stats():
        request = urllib.request.Request(f'http://127.0.0.1:{rc}/vfs/stats', data=b'{}', headers={
            'Content-Type': 'application/json', 'Authorization': 'Basic '+base64.b64encode(f'fixture:{token}'.encode()).decode()})
        with opener.open(request, timeout=2) as response: return json.load(response)

    def idle():
        disk = stats()['diskCache']
        counts = [disk[key] for key in ('uploadsQueued', 'uploadsInProgress', 'erroredFiles')]
        assert all(type(count) is int and count >= 0 for count in counts)
        return counts == [0, 0, 0] and disk['outOfSpace'] is False

    success = False
    try:
        local.until(stats)
        assert stats()['fs'].rstrip('/') == str(source)
        local.command(['/sbin/mount_nfs', '-o', f'port={nfs},mountport={nfs},tcp,vers=3,nolocks,mutejukebox,nodev,nosuid', '127.0.0.1:/', str(mount)])
        assert local.is_mounted(mount)
        local.filesystem('''import os,sys
from pathlib import Path
p=Path(sys.argv[1])
(p/'delete.bin').unlink()
(p/'overwrite.bin').write_bytes(b'new-overwrite')
(p/'replacement.tmp').write_bytes(b'new-replacement')
os.replace(p/'replacement.tmp',p/'replace.bin')
''', mount)
        local.command(['/sbin/umount', str(mount)])
        local.until(idle)
        assert not (source/'delete.bin').exists()
        assert (source/'overwrite.bin').read_bytes() == b'new-overwrite'
        assert (source/'replace.bin').read_bytes() == b'new-replacement'
        recovered = {hashlib.sha256(path.read_bytes()).hexdigest() for path in history.rglob('*') if path.is_file()}
        evidence = {'candidate': '--backup-dir on pinned NFS/VFS backend',
            'backendSHA256': hashlib.sha256(binary.read_bytes()).hexdigest(), 'mutationsCommitted': True,
            'priorBytesPreserved': {name: hashlib.sha256(data).hexdigest() in recovered for name, data in originals.items()},
            'historyObjectCount': len(recovered), 'remoteProviderTested': False}
        worker.terminate(); worker.wait(timeout=10)
        success = True
        print(json.dumps(evidence, indent=2))
    finally:
        safe = False
        try:
            if local.is_mounted(mount): local.command(['/sbin/umount', str(mount)])
            if not local.is_mounted(mount):
                if worker.poll() is None:
                    local.until(idle, seconds=10); worker.terminate(); worker.wait(timeout=10)
                safe = worker.poll() is not None
        except Exception: pass
        log.close()
        if success and safe: shutil.rmtree(root)
        else: print(f'Fixture retained: {root}; worker PID {worker.pid}', file=sys.stderr)


if __name__ == '__main__': main()
