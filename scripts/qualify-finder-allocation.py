#!/usr/bin/env python3
"""Qualify Finder/Foundation NFS allocation with generated local data only.

macOS POSIX stat uses synthesized total allocation for NFS, so st_blocks is
recorded diagnostically. Finder's URL resource allocation keys are the target.

Does not access the owner's profile, cache, credentials or R2. No cache purge.
Failure artifacts survive; recursive cleanup requires confirmed unmount/exit.
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
import time
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('local_qualification', ROOT/'scripts/qualify-local.py')
local = importlib.util.module_from_spec(spec)
spec.loader.exec_module(local)
SIZE = 8*1024*1024


def allocated(path):
    try:
        return path.stat().st_blocks*512
    except FileNotFoundError:
        return 0


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as handle:
        for block in iter(lambda: handle.read(1024*1024), b''):
            h.update(block)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rclone', type=pathlib.Path, default=ROOT/'build/backend/rclone')
    parser.add_argument('--manual-inspection', action='store_true', help='Pause for native Finder inspection; synthetic cache/writeback ages are extended to 120 seconds')
    args = parser.parse_args()
    binary = args.rclone.resolve(strict=True)
    root = pathlib.Path(tempfile.mkdtemp(prefix='clouddrive-finder-allocation-')).resolve()
    root.chmod(0o700)
    source, mount, cache = root/'source', root/'mount', root/'cache'
    source.mkdir(); mount.mkdir()
    remote = source/'remote.bin'
    remote.write_bytes(os.urandom(SIZE))
    expected = digest(remote)
    upload_payload = root/'upload-payload.bin'
    upload_payload.write_bytes(os.urandom(SIZE))
    upload_digest = digest(upload_payload)
    nfs, rc = local.port(), local.port()
    while nfs == rc:
        rc = local.port()
    token = os.urandom(32).hex()
    env = {key: os.environ[key] for key in ('PATH','HOME','TMPDIR','LANG') if key in os.environ}
    env.update(RCLONE_RC_USER='fixture', RCLONE_RC_PASS=token)
    log = (root/'worker.log').open('wb')
    worker = subprocess.Popen([
        str(binary),'serve','nfs',str(source),'--addr',f'127.0.0.1:{nfs}',
        '--config','/dev/null','--vfs-cache-mode','full','--cache-dir',str(cache),
        '--vfs-cache-max-age','120s' if args.manual_inspection else '1s','--vfs-cache-poll-interval','1s',
        '--vfs-write-back','120s' if args.manual_inspection else '2s','--bwlimit','1M','--rc','--rc-addr',f'127.0.0.1:{rc}'
    ], env=env, stdout=log, stderr=log)
    fd = os.open(root/'fixture-control.json', os.O_WRONLY|os.O_CREAT|os.O_EXCL, 0o600)
    with os.fdopen(fd,'w') as handle:
        json.dump({'pid':worker.pid,'controlPort':rc,'nfsPort':nfs,'token':token},handle)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    swift = root/'finder-allocation.swift'
    swift.write_text(r'''import Foundation
let v = try URL(fileURLWithPath: CommandLine.arguments[1]).resourceValues(forKeys: [.fileSizeKey,.fileAllocatedSizeKey,.totalFileAllocatedSizeKey])
let result: [String:Int] = ["size":v.fileSize ?? -1,"allocated":v.fileAllocatedSize ?? -1,"totalAllocated":v.totalFileAllocatedSize ?? -1]
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(data:data,encoding:.utf8)!)
''')
    finder_helper = root/'finder-allocation'
    passed, measurements = [], {}
    success = False

    def control(route='vfs/stats', parameters=None):
        request = urllib.request.Request(f'http://127.0.0.1:{rc}/{route}',data=json.dumps(parameters or {}).encode(),headers={
            'Content-Type':'application/json',
            'Authorization':'Basic '+base64.b64encode(f'fixture:{token}'.encode()).decode()})
        with opener.open(request, timeout=2) as response:
            return json.load(response)

    def inspect(phase, name, expected):
        if not args.manual_inspection:
            return
        ack = root / f'ack-{phase}'
        print(json.dumps({'inspection':phase, 'path':str(mount/name), 'expected':expected, 'acknowledge':str(ack), 'timeoutSeconds':100}), flush=True)
        local.until(ack.exists, seconds=100)
        measurements.setdefault('nativeInspectionAcknowledged', []).append(phase)

    def idle():
        disk = control()['diskCache']
        values = [disk[key] for key in ('uploadsQueued','uploadsInProgress','erroredFiles')]
        assert all(type(value) is int and value >= 0 for value in values)
        return values == [0,0,0] and disk['outOfSpace'] is False

    def mounted_stat(name):
        output = local.command([sys.executable,'-c',
            'import json,os,sys;s=os.stat(sys.argv[1]);print(json.dumps({"size":s.st_size,"allocated":s.st_blocks*512}))',
            str(mount/name)], timeout=5)
        return json.loads(output)

    def finder_stat(name):
        return json.loads(local.command([str(finder_helper),str(mount/name)],timeout=5))

    def mount_fixture():
        assert not local.is_mounted(mount)
        local.command(['/sbin/mount_nfs','-o',
            f'port={nfs},mountport={nfs},tcp,vers=3,nolocks,nodev,nosuid,acregmin=0,acregmax=1',
            '127.0.0.1:/',str(mount)])
        assert local.is_mounted(mount)

    try:
        local.command(['/usr/bin/swiftc',str(swift),'-o',str(finder_helper)],timeout=20)
        local.until(control)
        assert control()['fs'].rstrip('/') == str(source)
        cache_root = pathlib.Path(control()['diskCache']['path'])
        assert str(cache_root).startswith(str(cache)+'/')
        cached_remote, cached_upload = cache_root/'remote.bin', cache_root/'upload.bin'
        mount_fixture()
        passed.append('isolated native NFS mount with one-second allocation attribute TTL')
        initial = finder_stat('remote.bin')
        measurements['posix_stat_uncached'] = mounted_stat('remote.bin')
        assert initial == {'size':SIZE,'allocated':0,'totalAllocated':0}, initial
        assert allocated(cached_remote) == 0
        measurements['uncached_remote'] = initial
        passed.append('uncached remote logical size preserved with zero reported local allocation')

        inspect('cold', 'remote.bin', initial)

        local.filesystem('''
import hashlib,sys
with open(sys.argv[1],'rb') as handle:
 handle.seek(1024*1024)
 data=handle.read(1024*1024)
assert len(data)==1024*1024
''',mount/'remote.bin')
        observed = {}
        def partial_visible():
            current = finder_stat('remote.bin')
            physical = allocated(cached_remote)
            if current['size']==SIZE and physical>0 and current['allocated']==physical:
                observed.update(current);observed['cacheAllocated']=physical;return True
            return False
        local.until(partial_visible,seconds=5)
        measurements['after_partial_read'] = observed
        passed.append('cached read reports actual positive allocated blocks rather than fabricated zero')
        inspect('partial', 'remote.bin', observed)
        local.until(lambda: allocated(cached_remote)==0,seconds=150 if args.manual_inspection else 15)
        local.until(lambda: finder_stat('remote.bin')=={'size':SIZE,'allocated':0,'totalAllocated':0},seconds=8)
        measurements['after_read_eviction'] = finder_stat('remote.bin')
        passed.append('automatic read eviction updates reported allocation to zero without changing logical size')

        local.filesystem('''
import os,shutil,sys
with open(sys.argv[1],'rb') as src,open(sys.argv[2],'xb') as dst:
 shutil.copyfileobj(src,dst,1024*1024);dst.flush();os.fsync(dst.fileno())
''',upload_payload,mount/'upload.bin')
        dirty = {}
        def dirty_visible():
            current = finder_stat('upload.bin')
            physical = allocated(cached_upload)
            if not idle() and current['size']==SIZE and physical>0 and current['allocated']==physical:
                dirty.update(current);dirty['cacheAllocated']=physical;return True
            return False
        local.until(dirty_visible,seconds=5)
        measurements['dirty_upload'] = dirty
        passed.append('pending upload reports actual local dirty allocation and preserves full logical size')
        inspect('dirty', 'upload.bin', dirty)
        if args.manual_inspection:
            queue = control('vfs/queue')['queue']
            match = [item for item in queue if item['name']=='upload.bin' and item['uploading'] is False]
            assert len(match)==1, queue
            control('vfs/queue-set-expiry', {'id':match[0]['id'], 'expiry':-1000000000})
        # Pending writes outlive the max-age repeatedly; no cache files are manually deleted.
        for _ in range(4):
            assert not idle()
            assert allocated(cached_upload)>0
            time.sleep(.3)
        passed.append('dirty data retained while clean-cache age expires')
        local.until(idle,seconds=30)
        assert digest(source/'upload.bin')==upload_digest
        passed.append('independent backend upload SHA-256 matches')
        local.until(lambda: allocated(cached_upload)==0,seconds=150 if args.manual_inspection else 15)
        local.until(lambda: finder_stat('upload.bin')=={'size':SIZE,'allocated':0,'totalAllocated':0},seconds=8)
        measurements['after_upload_eviction'] = finder_stat('upload.bin')
        passed.append('uploaded data auto-evicts and NFS allocation returns to zero')

        inspect('evicted', 'upload.bin', measurements['after_upload_eviction'])

        # Remount defeats the Mac's data page cache before the full checksum read.
        local.command(['/sbin/umount',str(mount)])
        assert worker.poll() is None
        mount_fixture()
        local.filesystem('''
import hashlib,sys
h=hashlib.sha256()
with open(sys.argv[1],'rb') as handle:
 for block in iter(lambda:handle.read(256*1024),b''):h.update(block)
assert h.hexdigest()==sys.argv[2]
''',mount/'remote.bin',expected)
        passed.append('cold read after remount preserves complete file SHA-256')
        local.until(lambda: allocated(cached_remote)==0,seconds=150 if args.manual_inspection else 15)
        local.until(lambda: finder_stat('remote.bin')=={'size':SIZE,'allocated':0,'totalAllocated':0},seconds=8)
        measurements['after_cold_read_eviction'] = finder_stat('remote.bin')
        assert digest(remote)==expected
        passed.append('cold-read cache evicts again and backend object remains unchanged')
        local.command(['/sbin/umount',str(mount)])
        local.until(idle)
        worker.terminate();worker.wait(timeout=10)
        assert worker.poll() is not None
        passed.append('normal unmount and confirmed storage worker exit')
        success = True
    finally:
        safe = False
        try:
            if local.is_mounted(mount):local.command(['/sbin/umount',str(mount)])
            if not local.is_mounted(mount):
                if worker.poll() is None:
                    local.until(idle,seconds=10);worker.terminate();worker.wait(timeout=10)
                safe = worker.poll() is not None
        except Exception:
            pass
        log.close()
        if args.manual_inspection:
            report = {'passed':passed, 'measurements':measurements, 'backend':str(binary),
                      'manualInspection':True, 'success':success, 'safeTeardown':safe,
                      'fixtureRetained':None if success and safe else str(root),
                      'nativeUIAcceptance':'requires separate recorded Finder evidence'}
            (ROOT/'build').mkdir(exist_ok=True)
            (ROOT/'build/finder-manual-allocation-report.json').write_text(json.dumps(report,indent=2))
        if success and safe:
            shutil.rmtree(root)
            print(json.dumps({'passed':passed+['safe disposable fixture cleanup'],'measurements':measurements},indent=2))
        else:
            print(f'Fixture retained at {root}; worker PID {worker.pid}. Never recursively remove a mounted fixture.',file=sys.stderr)
            if success:raise RuntimeError('qualification passed but cleanup was not safe')


if __name__=='__main__':main()
