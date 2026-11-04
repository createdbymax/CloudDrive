#!/usr/bin/env python3
"""Prove backend-managed clean-cache eviction with an isolated macOS NFS fixture.

Never reads owner credentials/state or calls a cloud provider. No cache purge or
manual cache deletion is used. Failure artifacts are retained after safe unmount.
"""
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
import time
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('local_qualification', ROOT/'scripts/qualify-local.py')
local = importlib.util.module_from_spec(spec)
spec.loader.exec_module(local)


def allocated(path):
    try:
        return path.stat().st_blocks * 512
    except FileNotFoundError:
        return 0


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024*1024), b''):
            h.update(chunk)
    return h.hexdigest()


def main():
    root = pathlib.Path(tempfile.mkdtemp(prefix='clouddrive-cloud-cache-')).resolve()
    root.chmod(0o700)
    source, mount, cache = root/'source', root/'mount', root/'cache'
    source.mkdir(); mount.mkdir()
    payload = root/'expected.bin'
    payload.write_bytes(os.urandom(8*1024*1024))
    expected = digest(payload)
    nfs, rc = local.port(), local.port()
    while nfs == rc:
        rc = local.port()
    token = os.urandom(32).hex()
    env = {k: os.environ[k] for k in ('PATH','HOME','TMPDIR','LANG') if k in os.environ}
    env.update(RCLONE_RC_USER='fixture', RCLONE_RC_PASS=token)
    log = (root/'worker.log').open('wb')
    worker = subprocess.Popen([
        str(ROOT/'build/backend/rclone'), 'serve', 'nfs', str(source),
        '--addr', f'127.0.0.1:{nfs}', '--config', '/dev/null',
        '--vfs-cache-mode','full','--cache-dir',str(cache),
        '--vfs-cache-max-age','1s','--vfs-cache-poll-interval','1s',
        '--vfs-write-back','2s','--vfs-cache-max-size','5G',
        '--bwlimit','1M','--rc','--rc-addr',f'127.0.0.1:{rc}'
    ], env=env, stdout=log, stderr=log)
    fd = os.open(root/'fixture-control.json', os.O_WRONLY|os.O_CREAT|os.O_EXCL, 0o600)
    with os.fdopen(fd,'w') as handle:
        json.dump({'pid':worker.pid,'nfsPort':nfs,'controlPort':rc,'token':token},handle)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    passed, measurements = [], {}
    success = False

    def control(route='vfs/stats'):
        req = urllib.request.Request(f'http://127.0.0.1:{rc}/{route}', data=b'{}', headers={
            'Content-Type':'application/json',
            'Authorization':'Basic '+base64.b64encode(f'fixture:{token}'.encode()).decode()})
        with opener.open(req,timeout=2) as response:
            return json.load(response)

    def idle():
        d = control()['diskCache']
        values = [d[k] for k in ('uploadsQueued','uploadsInProgress','erroredFiles')]
        assert all(type(v) is int and v >= 0 for v in values)
        return values == [0,0,0] and d['outOfSpace'] is False

    try:
        local.until(control)
        stats = control()
        assert stats['fs'].rstrip('/') == str(source)
        cache_root = pathlib.Path(stats['diskCache']['path'])
        assert str(cache_root).startswith(str(cache)+'/')
        cached = cache_root/'upload.bin'
        assert not local.is_mounted(mount)
        local.command(['/sbin/mount_nfs','-o',f'port={nfs},mountport={nfs},tcp,vers=3,nolocks,nodev,nosuid','127.0.0.1:/',str(mount)])
        assert local.is_mounted(mount)
        passed.append('isolated native mount with cloud-first cache settings')
        started = time.monotonic()
        local.filesystem('''
import os,pathlib,shutil,sys
with open(sys.argv[1],'rb') as src, open(sys.argv[2],'xb') as dst:
 shutil.copyfileobj(src,dst,1024*1024);dst.flush();os.fsync(dst.fileno())
''',payload,mount/'upload.bin')
        local.until(lambda: not idle() and cached.exists(),seconds=5)
        dirty_min = allocated(cached)
        assert dirty_min > 0
        # Age and cleaner intervals both expire repeatedly during this throttled upload.
        for _ in range(6):
            assert not idle(), 'fixture upload completed before dirty retention observation'
            assert cached.exists() and cached.stat().st_size == payload.stat().st_size
            assert allocated(cached) > 0
            time.sleep(.4)
        measurements['dirty_cache_allocated_bytes'] = dirty_min
        passed.append('dirty/pending 8 MiB upload retained beyond clean-cache max age')
        local.until(idle,seconds=30)
        committed = time.monotonic()
        assert digest(source/'upload.bin') == expected
        passed.append('independent backend SHA-256 matches after upload queue drains')
        local.until(lambda: not cached.exists(),seconds=15)
        measurements['upload_to_clean_eviction_seconds'] = round(time.monotonic()-started,3)
        measurements['observed_idle_to_eviction_seconds'] = round(time.monotonic()-committed,3)
        measurements['clean_cache_allocated_bytes_after_eviction'] = allocated(cached)
        assert allocated(cached) == 0
        passed.append('uploaded closed file automatically evicted without manual deletion')
        # A failed upload must remain locally recoverable regardless of max age.
        failed_name = 'retry-after-denied.bin'
        failed_cache = cache_root/failed_name
        failed_payload = root/'retry-payload.bin'
        failed_payload.write_bytes(os.urandom(1024*1024))
        failed_digest = digest(failed_payload)
        source.chmod(0o500)
        try:
            local.filesystem('''
import os,shutil,sys
with open(sys.argv[1],'rb') as src, open(sys.argv[2],'xb') as dst:
 shutil.copyfileobj(src,dst);dst.flush();os.fsync(dst.fileno())
''',failed_payload,mount/failed_name)
            local.until(lambda: control('core/stats')['errors'] > 0 and control()['diskCache']['uploadsQueued'] > 0,seconds=15)
            for _ in range(5):
                assert failed_cache.exists() and failed_cache.stat().st_size==1024*1024
                assert digest(failed_cache)==failed_digest
                time.sleep(.4)
            assert not (source/failed_name).exists()
            passed.append('upload failure retains complete dirty cache beyond max age')
        finally:
            source.chmod(0o700)
        local.until(idle,seconds=30)
        assert digest(source/failed_name)==failed_digest
        local.until(lambda:not failed_cache.exists(),seconds=15)
        passed.append('failed upload retries after backend recovery then evicts safely')
        # Ensure kernel page cache cannot satisfy the next read: unmount/remount the
        # fixture while leaving its backend/cache worker alive.
        local.command(['/sbin/umount',str(mount)])
        assert worker.poll() is None
        local.command(['/sbin/mount_nfs','-o',f'port={nfs},mountport={nfs},tcp,vers=3,nolocks,nodev,nosuid','127.0.0.1:/',str(mount)])
        reader = subprocess.Popen([sys.executable,'-c','''
import hashlib,pathlib,sys,time
p=pathlib.Path(sys.argv[1]);h=hashlib.sha256()
with p.open('rb') as f:
 for block in iter(lambda:f.read(256*1024),b''):
  h.update(block);time.sleep(.03)
assert h.hexdigest()==sys.argv[2]
''',str(mount/'upload.bin'),expected], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        peak = 0
        deadline = time.monotonic()+25
        while reader.poll() is None and time.monotonic()<deadline:
            peak = max(peak,allocated(cached));time.sleep(.1)
        if reader.poll() is None:
            reader.kill()
            raise RuntimeError('cold-read helper exceeded deadline; fixture retained')
        assert reader.returncode == 0
        assert peak > 0, 'cold read did not visibly materialize cache blocks'
        measurements['cold_read_peak_allocated_bytes'] = peak
        passed.append('cold read after unmount/remount re-fetches correct backend bytes')
        # Quiet Mac descriptors are not an rclone open-lifetime guarantee under NFSv3.
        # The relevant contract is reproducible clean content plus dirty-data retention.
        cold_finished = time.monotonic()
        local.until(lambda: not cached.exists(),seconds=15)
        measurements['cold_read_close_to_eviction_seconds'] = round(time.monotonic()-cold_finished,3)
        assert digest(source/'upload.bin') == expected
        passed.append('cold-read cache automatically evicted again; backend object unchanged')
        local.command(['/sbin/umount',str(mount)])
        local.until(idle)
        worker.terminate();worker.wait(timeout=10)
        assert worker.poll() is not None
        passed.append('safe normal unmount and confirmed worker exit')
        success = True
    finally:
        safe = False
        try:
            if local.is_mounted(mount):
                local.command(['/sbin/umount',str(mount)])
            if not local.is_mounted(mount):
                if worker.poll() is None:
                    local.until(idle,seconds=10)
                    worker.terminate();worker.wait(timeout=10)
                safe = worker.poll() is not None
        except Exception:
            pass
        try:
            source.chmod(0o700)
        except OSError:
            pass
        log.close()
        if success and safe:
            shutil.rmtree(root)
            print(json.dumps({'passed':passed+['safe disposable fixture cleanup'],'measurements':measurements},indent=2))
        else:
            print(f'Fixture retained at {root}; worker PID {worker.pid}. Never recursively remove a mounted fixture.',file=sys.stderr)
            if success:
                raise RuntimeError('qualification passed but cleanup was not safe')


if __name__=='__main__':
    main()
