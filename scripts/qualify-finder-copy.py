#!/usr/bin/env python3
"""Native Finder copy checkpoint, isolated local NFS only; never the owner drive.

Copy printed source into printed mount with Finder, then create ack-finder-done.
No GUI automation is performed here. Successful teardown requires normal unmount.
"""
import base64
import hashlib
import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import time
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('local', ROOT/'scripts/qualify-local.py')
local = importlib.util.module_from_spec(spec); spec.loader.exec_module(local)


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024*1024), b''): h.update(chunk)
    return h.hexdigest()


def main():
    root = pathlib.Path(tempfile.mkdtemp(prefix='clouddrive-finder-copy-')).resolve()
    root.chmod(0o700)
    source, mount, backend = (root/name for name in ('source', 'mount', 'backend'))
    for path in (source, mount, backend): path.mkdir()
    payload = source/'finder-fixture.dat'
    with payload.open('xb') as f:
        for _ in range(256): f.write(os.urandom(1024*1024))
    expected = digest(payload)
    nfs, rc = local.port(), local.port()
    while nfs == rc: rc = local.port()
    token = os.urandom(32).hex()
    env = {k: os.environ[k] for k in ('PATH', 'HOME', 'TMPDIR', 'LANG') if k in os.environ}
    env.update(RCLONE_RC_USER='fixture', RCLONE_RC_PASS=token)
    log = (root/'worker.log').open('wb')
    worker = subprocess.Popen([str(ROOT/'build/backend/rclone'), 'serve', 'nfs', str(backend),
        '--addr', f'127.0.0.1:{nfs}', '--config', '/dev/null', '--cache-dir', str(root/'cache'),
        '--vfs-cache-mode', 'full', '--vfs-write-back', '2s', '--vfs-cache-max-age', '1s',
        '--vfs-cache-poll-interval', '1s', '--buffer-size', '4M', '--rc', '--rc-addr', f'127.0.0.1:{rc}'],
        env=env, stdout=log, stderr=log)
    fd = os.open(root/'fixture-control.json', os.O_CREAT|os.O_EXCL|os.O_WRONLY, 0o600)
    with os.fdopen(fd, 'w') as f: json.dump({'pid': worker.pid, 'port': rc, 'token': token}, f)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def stats():
        request = urllib.request.Request(f'http://127.0.0.1:{rc}/vfs/stats', data=b'{}', headers={
            'Content-Type': 'application/json', 'Authorization': 'Basic '+base64.b64encode(f'fixture:{token}'.encode()).decode()})
        with opener.open(request, timeout=2) as h: return json.load(h)

    def idle():
        d = stats()['diskCache']
        values = [d[k] for k in ('uploadsQueued', 'uploadsInProgress', 'erroredFiles')]
        assert all(type(x) is int and x >= 0 for x in values)
        return values == [0, 0, 0] and d['outOfSpace'] is False

    success, safe = False, False
    timeline = {}
    started = time.monotonic()
    try:
        local.until(stats)
        assert stats()['fs'].rstrip('/') == str(backend)
        cache_root = pathlib.Path(stats()['diskCache']['path'])
        assert root/'cache' in cache_root.parents
        local.command(['/sbin/mount_nfs', '-o', f'port={nfs},mountport={nfs},tcp,vers=3,nolocks,mutejukebox,nodev,nosuid,acregmin=0,acregmax=1', '127.0.0.1:/', str(mount)])
        print(json.dumps({'source': str(payload), 'destination': str(mount), 'ack': str(root/'ack-finder-done'), 'deadlineSeconds': 180}), flush=True)
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            d = stats()['diskCache']
            try: size = (cache_root/payload.name).stat().st_size
            except FileNotFoundError: size = 0
            if size and 'firstLocalDataSeconds' not in timeline: timeline['firstLocalDataSeconds'] = time.monotonic()-started
            if size == payload.stat().st_size and 'fullCacheSeconds' not in timeline: timeline['fullCacheSeconds'] = time.monotonic()-started
            if d['uploadsInProgress'] and 'uploadObservedSeconds' not in timeline: timeline['uploadObservedSeconds'] = time.monotonic()-started
            if (root/'ack-finder-done').exists():
                timeline['finderCompletionAcknowledgedSeconds'] = time.monotonic()-started
                break
            time.sleep(.1)
        else: raise RuntimeError('Finder inspection deadline exceeded')
        local.until(lambda: (backend/payload.name).exists() and idle(), seconds=30)
        assert digest(backend/payload.name) == expected
        timeline['independentBackendChecksum'] = True
        local.until(lambda: not (cache_root/payload.name).exists(), seconds=20)
        timeline['automaticCacheReclamation'] = True
        success = True
    finally:
        try:
            if local.is_mounted(mount): local.command(['/sbin/umount', str(mount)])
            if not local.is_mounted(mount):
                if worker.poll() is None: local.until(idle, seconds=15); worker.terminate(); worker.wait(timeout=10)
                safe = worker.poll() is not None
        except Exception: pass
        log.close()
        report = {'success': success, 'safeShutdown': safe, 'sizeBytes': payload.stat().st_size,
            'timeline': timeline, 'scope': 'native Finder, local filesystem backend; no network/provider qualification',
            'fixtureRetained': None if success and safe else str(root)}
        pathlib.Path('/tmp/clouddrive-finder-copy-report.json').write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps(report), flush=True)
        if success and safe: shutil.rmtree(root)


if __name__ == '__main__': main()
