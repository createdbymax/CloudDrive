#!/usr/bin/env python3
"""Disposable native NFS move qualification. Never reads a saved connection.

Uses generated data, a loopback worker and normal unmount. Failed fixtures are
retained with private diagnostics; no mounted tree is recursively removed.
"""
import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('local_qualification', ROOT/'scripts/qualify-local.py')
local = importlib.util.module_from_spec(spec); spec.loader.exec_module(local)

RENAME_RETRY = '''
import errno, os, time
def rename_retry(source, destination, timeout=60, **descriptors):
    deadline = time.monotonic() + timeout
    while True:
        try:
            os.rename(source, destination, **descriptors)
            return
        except OSError as error:
            if error.errno not in (errno.EAGAIN, errno.EBUSY) or time.monotonic() >= deadline:
                raise
            time.sleep(.1)
'''

DIRECTORY_FD_PROBE = RENAME_RETRY + '''
import json,os,pathlib,sys,time
mount, records=pathlib.Path(sys.argv[1]),pathlib.Path(sys.argv[2])
directory=os.open(mount/'Unrelated',os.O_RDONLY)
try:
    (records/'fd-probe-ready').write_text('ready')
    for command in sys.stdin:
        phase=command.strip()
        if phase=='quit': break
        if phase=='rename':
            fd=os.open('created-during-copy', os.O_WRONLY|os.O_CREAT|os.O_EXCL, 0o600, dir_fd=directory)
            try:
                assert os.write(fd,b'concurrent Finder write')==23
                os.fsync(fd)
            finally: os.close(fd)
            rename_retry('Quick', 'Quick moved', timeout=12, src_dir_fd=directory, dst_dir_fd=directory)
            (records/'concurrent-native-ready').touch()
            continue
        name={'inventory':'preparing-probe.bin','copy':'probe.bin'}[phase]
        started=time.monotonic()
        print('probe '+phase+': stat via existing unrelated directory FD',file=sys.stderr,flush=True)
        assert os.stat(name,dir_fd=directory).st_size==len(b'unrelated resident bytes')
        descriptor=os.open(name,os.O_RDONLY,dir_fd=directory)
        try:
            print('probe '+phase+': read via existing unrelated directory FD',file=sys.stderr,flush=True)
            assert os.read(descriptor,64)==b'unrelated resident bytes'
        finally: os.close(descriptor)
        print('probe '+phase+': list existing unrelated directory FD',file=sys.stderr,flush=True)
        assert {'probe.bin','listing-only.txt'}<=set(os.listdir(directory))
        (records/('fd-probe-'+phase+'.json')).write_text(json.dumps({'seconds':time.monotonic()-started}))
finally: os.close(directory)
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--backend', type=Path, default=ROOT/'build/backend/rclone')
    parser.add_argument('--finder', action='store_true', help='Also ask Finder to move two generated items.')
    parser.add_argument('--s3', action='store_true', help='Exercise a loopback S3 copy/delete backend and injected recovery.')
    parser.add_argument('--slow', action='store_true', help='Also prove unrelated Finder/NFS access stays responsive during a paused remote folder move; implies --s3.')
    parser.add_argument('--slow-objects', type=int, default=64, help='Generated objects in the slow folder (2–10000; default 64).')
    parser.add_argument('--metadata-delay', type=float, default=.005, help='Seconds of latency per slow-prefix HEAD/list request (0–1).')
    parser.add_argument('--copy-delay', type=float, default=.02, help='Seconds of latency per slow-prefix copy request after releasing its pause (0–1).')
    parser.add_argument('--probe-timeout', type=float, default=3, help='Deadline for all unrelated mounted stat/read/list probes (0.5–10 seconds).')
    parser.add_argument('--slow-timeout', type=float, default=120, help='Overall slow rename/phase completion deadline (10–600 seconds); does not relax the probe deadline.')
    parser.add_argument('--independent-mount', action='store_true', help='Also probe server root metadata from a second readonly native mount; implies --slow.')
    parser.add_argument('--concurrent', action='store_true', help='Prove another mounted rename and a move to the same destination parent finish while a slow copy is paused.')
    args = parser.parse_args()
    if not 2 <= args.slow_objects <= 10000: parser.error('--slow-objects must be between 2 and 10000')
    if not 0 <= args.metadata_delay <= 1 or not 0 <= args.copy_delay <= 1: parser.error('request delays must be between 0 and 1 second')
    if not .5 <= args.probe_timeout <= 10: parser.error('--probe-timeout must be between 0.5 and 10 seconds')
    if not 10 <= args.slow_timeout <= 600: parser.error('--slow-timeout must be between 10 and 600 seconds')
    args.slow = args.slow or args.independent_mount or args.concurrent
    args.s3 = args.s3 or args.slow
    root = Path(tempfile.mkdtemp(prefix='clouddrive-moves-')).resolve(); root.chmod(0o700)
    source, mount = root/'source', root/'mount'; source.mkdir(); mount.mkdir()
    (source/'Album/Sub').mkdir(parents=True); (source/'Target').mkdir()
    (source/'Album/Sub/Résumé.wav').write_bytes(b'original payload' * 1024)
    (source/'Target/Album').mkdir(); (source/'Target/Album/keep').write_bytes(b'keep sibling')
    (source/'loose.bin').write_bytes(b'loose')
    if args.s3: (source/'Album/uncached-large.bin').write_bytes(b'L'*(6*1024*1024))
    if args.slow:
        (source/'Unrelated').mkdir()
        (source/'Unrelated/probe.bin').write_bytes(b'unrelated resident bytes')
        (source/'Unrelated/preparing-probe.bin').write_bytes(b'unrelated resident bytes')
        (source/'Unrelated/listing-only.txt').write_bytes(b'keep unrelated sibling')
        for index in range(args.slow_objects):
            folder = source/'Slow'/f'Disc-{index//8:03d}'; folder.mkdir(parents=True, exist_ok=True)
            (folder/f'track-{index:04d}.bin').write_bytes(f'generated move payload {index}'.encode()*32)
    if args.concurrent:
        for path in ('Unrelated/Quick', 'Second', 'Occupied', 'Shared parent sibling', 'Raced'):
            (source/path).mkdir()
            (source/path/'test.bin').write_bytes(path.encode())
        companion_bytes = {}
        for name in ('Second', 'Shared parent sibling'):
            fork = b'qualification resource fork for ' + name.encode()
            header = struct.pack('>II16sHIII', 0x51607, 0x20000, bytes(16), 1, 2, 38, len(fork))
            companion_bytes[name] = header + fork
            (source / ('._' + name)).write_bytes(companion_bytes[name])
    nfs, rc = local.port(), local.port()
    while nfs == rc: rc = local.port()
    password = os.urandom(32).hex()
    env = {k: os.environ[k] for k in ('PATH', 'HOME', 'TMPDIR', 'LANG') if k in os.environ}
    env.update(RCLONE_RC_USER='fixture', RCLONE_RC_PASS=password)
    s3 = None
    remote = str(source)
    if args.s3:
        spec = importlib.util.spec_from_file_location('moves_s3', ROOT/'scripts/fixtures/moves-s3-fixture.py')
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        s3 = module.start(source, root, metadata_delay=args.metadata_delay if args.slow else 0,
                          copy_delay=args.copy_delay if args.slow else 0,
                          slow_prefixes=('prefix/Slow/', 'prefix/Target/Slow moved/') if args.slow else ())
        remote = ':s3:fixture/prefix'
        env.update(RCLONE_S3_PROVIDER='Cloudflare' if args.concurrent else 'Other', RCLONE_S3_ACCESS_KEY_ID='fixture-access',
                   RCLONE_S3_SECRET_ACCESS_KEY='fixture-secret', RCLONE_S3_REGION='auto',
                   RCLONE_S3_ENDPOINT=f'http://127.0.0.1:{s3.server_port}', RCLONE_S3_FORCE_PATH_STYLE='true',
                   RCLONE_S3_DIRECTORY_MARKERS='true', RCLONE_S3_LIST_VERSION='2')
    command = [str(args.backend.resolve()), 'serve', 'nfs', remote, '--config', '/dev/null',
               '--addr', f'127.0.0.1:{nfs}', '--cache-dir', str(root/'cache'), '--vfs-cache-mode', 'full',
               '--vfs-write-back', '1s', '--vfs-move-journal', str(root/'moves'),
               '--rc', '--rc-addr', f'127.0.0.1:{rc}', '--low-level-retries', '1', '--retries', '1',
               '--s3-copy-cutoff', '5M', '-vv']
    log = (root/'worker.log').open('wb'); os.chmod(root/'worker.log', 0o600)
    worker = subprocess.Popen(command, env=env, stdout=subprocess.DEVNULL, stderr=log)
    record = root/'fixture-control.json'; record.write_text(json.dumps({'pid': worker.pid, 'controlPort': rc, 'nfsPort': nfs, 'token': password})); record.chmod(0o600)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    def control(route='vfs/stats', body=None):
        request = urllib.request.Request(f'http://127.0.0.1:{rc}/{route}', data=json.dumps(body or {}).encode(),
            headers={'Content-Type': 'application/json', 'Authorization': 'Basic '+base64.b64encode(f'fixture:{password}'.encode()).decode()})
        with opener.open(request, timeout=3) as response: return json.load(response)
    def filesystem(code, mounted, timeout=60):
        try: local.command([sys.executable, '-c', "import sys;sys.stderr=open(sys.argv[2], 'w')\n"+RENAME_RETRY+code,
                            str(mounted), str(root/'helper.stderr')], timeout=timeout)
        except Exception:
            error = root/'helper.stderr'
            if error.exists(): print(error.read_text()[-1500:], file=sys.stderr)
            raise
    passed = []; metrics = {}; children = []; extra_mounts = []; success = False
    try:
        def ready():
            if worker.poll() is not None: raise RuntimeError('fixture worker exited; inspect retained worker.log')
            return control()
        local.until(ready)
        local.command(['/sbin/mount_nfs', '-o', f'port={nfs},mountport={nfs},tcp,vers=3,nolocks,mutejukebox,nodev,nosuid,acregmin=0,acregmax=1', '127.0.0.1:/', str(mount)])
        assert local.is_mounted(mount)
        filesystem('''
import os,pathlib,sys
m=pathlib.Path(sys.argv[1])
f=os.open(m/'Album/Sub/Résumé.wav',os.O_RDONLY)
d=os.open(m/'Album/Sub',os.O_RDONLY)
try:
    before=os.fstat(f); expected=os.read(f,32768)
    rename_retry(m/'Album',m/'Target/Moved Album')
    assert os.fstat(f).st_ino==before.st_ino
    assert os.stat('Résumé.wav',dir_fd=d).st_size==before.st_size
    os.lseek(f,0,0);assert os.read(f,32768)==expected
    assert (m/'Target/Moved Album/Sub/Résumé.wav').read_bytes()==expected
    assert (m/'Target/Album/keep').read_bytes()==b'keep sibling'
    rename_retry(m/'loose.bin',m/'Target/loose.bin')
finally: os.close(f);os.close(d)
''', mount)
        passed += ['cross-parent folder move', 'open child file and directory handle continuity', 'destination sibling preserved', 'cross-parent file move']
        status = control('vfs/moves'); assert not status['active'] and not status['needsRecovery']
        if args.slow:
            with s3.guard:
                expected = {key: value['data'] for key, value in s3.objects.items()
                            if key.startswith('prefix/Slow/') and not key.endswith('/')}
            fd_errors = (root/'fd-probe.stderr').open('wb'); os.chmod(fd_errors.name, 0o600)
            fd_probe = subprocess.Popen([sys.executable, '-u', '-c', DIRECTORY_FD_PROBE, str(mount), str(root)],
                                        stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=fd_errors, text=True)
            children.append(fd_probe)
            local.until(lambda: (root/'fd-probe-ready').exists(), seconds=10)
            shared_child = None
            if args.concurrent:
                # Open the precise two Finder parent directories before the first rename starts.
                shared_script = RENAME_RETRY + """
import pathlib,sys
m=pathlib.Path(sys.argv[1]); evidence=pathlib.Path(sys.argv[2])
a=os.open(m,os.O_RDONLY); b=os.open(m/'Target',os.O_RDONLY)
(evidence/'shared-parent-ready').touch()
if sys.stdin.readline().strip()=='move':
    rename_retry('Shared parent sibling','Shared parent sibling',src_dir_fd=a,dst_dir_fd=b)
"""
                shared_child = subprocess.Popen([sys.executable,'-c',shared_script,str(mount),str(root)],
                                                stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=log, text=True)
                children.append(shared_child)
                local.until(lambda: (root/'shared-parent-ready').exists(), seconds=10)
            independent = None
            if args.independent_mount:
                independent = root/'independent-mount'; independent.mkdir(); extra_mounts.append(independent)
                local.command(['/sbin/mount_nfs', '-o',
                               f'port={nfs},mountport={nfs},tcp,vers=3,ro,nolocks,mutejukebox,nodev,nosuid,acregmin=0,acregmax=1,acdirmin=0,acdirmax=0',
                               '127.0.0.1:/', str(independent)])
                assert local.is_mounted(independent)
            s3.copy_entered.clear(); s3.copy_release.clear()
            s3.inventory_entered.clear(); s3.inventory_release.clear()
            child_errors = (root/'slow-rename.stderr').open('wb'); os.chmod(child_errors.name, 0o600)
            child = subprocess.Popen([sys.executable, '-c', RENAME_RETRY+'\nimport sys\nrename_retry(sys.argv[1],sys.argv[2],float(sys.argv[3]))',
                                      str(mount/'Slow'), str(mount/'Target/Slow moved'), str(args.slow_timeout)],
                                     stdout=subprocess.DEVNULL, stderr=child_errors)
            children.append(child)
            try:
                def phase_is_paused(event):
                    if child.poll() is not None:
                        raise RuntimeError('native rename ended before the remote pause: '+(root/'slow-rename.stderr').read_text()[-1500:])
                    state = control('vfs/moves')
                    if state['needsRecovery']: raise RuntimeError('slow move failed before the remote pause: '+state.get('message', ''))
                    return event.is_set()
                def probe_unrelated(phase):
                    assert child.poll() is None, 'native rename returned before the paused remote move completed'
                    assert control('vfs/moves')['active'], 'remote pause did not hold an active move'
                    fd_probe.stdin.write(phase+'\n'); fd_probe.stdin.flush()
                    def probe_ready():
                        if fd_probe.poll() is not None:
                            raise RuntimeError('directory-FD probe exited: '+(root/'fd-probe.stderr').read_text()[-1500:])
                        return (root/('fd-probe-'+phase+'.json')).exists()
                    local.until(probe_ready, seconds=args.probe_timeout)
                    result = json.loads((root/('fd-probe-'+phase+'.json')).read_text())
                    assert result['seconds'] < args.probe_timeout
                    metrics[phase+'DirectoryFdProbeSeconds'] = round(result['seconds'], 3)
                    assert control('vfs/moves')['active'], 'directory-FD probe did not overlap the paused move'
                    if independent is None: return
                    before_probe = time.monotonic()
                    filesystem('''
import pathlib,sys
m=pathlib.Path(sys.argv[1]); p=m/'Unrelated'/'PROBE_NAME'
print('probe: stat unrelated file', file=sys.stderr, flush=True)
assert p.stat().st_size==len(b'unrelated resident bytes')
print('probe: read unrelated file', file=sys.stderr, flush=True)
assert p.read_bytes()==b'unrelated resident bytes'
print('probe: list root', file=sys.stderr, flush=True)
assert 'Unrelated' in {p.name for p in m.iterdir()}
print('probe: list unrelated directory', file=sys.stderr, flush=True)
assert {'probe.bin','listing-only.txt'} <= {p.name for p in (m/'Unrelated').iterdir()}
print('probe: complete', file=sys.stderr, flush=True)
'''.replace('PROBE_NAME', 'preparing-probe.bin' if phase=='inventory' else 'probe.bin'), independent, timeout=args.probe_timeout)
                    metrics[phase+'IndependentMountProbeSeconds'] = round(time.monotonic()-before_probe, 3)
                    assert control('vfs/moves')['active'], 'probe did not overlap the paused move'
                local.until(lambda: phase_is_paused(s3.inventory_entered), seconds=args.slow_timeout)
                probe_unrelated('inventory')
                assert not s3.inventory_release.is_set(), 'inventory was not paused during its probe'
                passed.append('pre-opened unrelated directory FD stat/read/list stays responsive during paused inventory preparation')
                if independent: passed.append('independent native mount root and other-folder metadata stays responsive during paused inventory preparation')
                s3.inventory_release.set()
                local.until(lambda: phase_is_paused(s3.copy_entered), seconds=args.slow_timeout)
                probe_unrelated('copy')
                assert not s3.copy_release.is_set(), 'copy was not paused during its probe'
                passed.append('pre-opened unrelated directory FD stat/read/list stays responsive during paused server-side copy')
                if args.concurrent:
                    import uuid
                    fd_probe.stdin.write('rename\n'); fd_probe.stdin.flush()
                    local.until(lambda: (root/'concurrent-native-ready').exists(), seconds=15)
                    assert s3.objects['prefix/Unrelated/Quick moved/test.bin']['data'] == b'Unrelated/Quick'
                    def unrelated_write_published():
                        with s3.guard:
                            return s3.objects.get('prefix/Unrelated/created-during-copy', {}).get('data') == b'concurrent Finder write'
                    local.until(unrelated_write_published, seconds=10)
                    passed.append('independent mounted folder rename and file creation, fsync and publication finish during a paused copy')
                    request = {'source': 'Second', 'destination': 'Target/Second', 'requestID': str(uuid.uuid4())}
                    accepted = control('vfs/move', request)
                    assert accepted['accepted'] and accepted['id']
                    assert control('vfs/move', request) == accepted
                    def second_finished():
                        with s3.guard:
                            return ('prefix/Second/test.bin' not in s3.objects and
                                    s3.objects.get('prefix/Target/Second/test.bin', {}).get('data') == b'Second' and
                                    'prefix/._Second' not in s3.objects and
                                    s3.objects.get('prefix/Target/._Second', {}).get('data') == companion_bytes['Second'])
                    local.until(second_finished, seconds=15)
                    assert control('vfs/moves')['active'] and not s3.copy_release.is_set()
                    passed.append('same backup parent move and duplicate request completed while first copy remained paused')
                    passed.append('protected folder move preserved its sibling AppleDouble bytes and removed its old companion')
                    occupied = {'source': 'Occupied', 'destination': 'Target/Second', 'requestID': str(uuid.uuid4())}
                    try:
                        result = control('vfs/move', occupied)
                    except urllib.error.HTTPError:
                        pass
                    else:
                        assert result.get('accepted') is False, 'submitted occupied target'
                    with s3.guard:
                        assert s3.objects['prefix/Occupied/test.bin']['data'] == b'Occupied'
                        assert s3.objects['prefix/Target/Second/test.bin']['data'] == b'Second'
                    passed.append('existing same-name destination preserved')
                    shared_child.stdin.write('move\n'); shared_child.stdin.close()
                    try:
                        shared_child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        pass
                    metrics['sharedParentNativeFinishedDuringPause'] = shared_child.poll() == 0


                if independent: passed.append('independent native mount root and other-folder metadata stays responsive during paused server-side copy')
            finally:
                s3.inventory_release.set()
                s3.copy_release.set()
                if fd_probe.poll() is None:
                    fd_probe.stdin.write('quit\n'); fd_probe.stdin.flush(); fd_probe.stdin.close()
                    try: fd_probe.wait(timeout=2)
                    except subprocess.TimeoutExpired: pass
                fd_errors.close()
            try:
                local.until(lambda: child.poll() is not None, seconds=args.slow_timeout)
                result = child.returncode
            except RuntimeError:
                child.kill()
                raise RuntimeError('slow native rename exceeded deadline; owned fixture retained')
            finally: child_errors.close()
            if result:
                raise RuntimeError('slow native rename failed: '+(root/'slow-rename.stderr').read_text()[-1500:])
            if shared_child is not None:
                if shared_child.wait(timeout=30) != 0: raise RuntimeError('shared-parent mounted move failed')
                with s3.guard:
                    assert s3.objects['prefix/Target/Shared parent sibling/test.bin']['data'] == b'Shared parent sibling'
                    assert 'prefix/Shared parent sibling/test.bin' not in s3.objects
                    assert 'prefix/._Shared parent sibling' not in s3.objects
                    assert s3.objects['prefix/Target/._Shared parent sibling']['data'] == companion_bytes['Shared parent sibling']
                passed.append('two mounted moves into the same folder both completed')
            local.until(lambda: not control('vfs/moves')['active'])
            assert not control('vfs/moves')['needsRecovery']
            with s3.guard:
                for key, payload in expected.items():
                    target = 'prefix/Target/Slow moved/'+key.removeprefix('prefix/Slow/')
                    assert s3.objects[target]['data'] == payload, target
                assert not any(key.startswith('prefix/Slow/') for key in s3.objects), 'source objects remain after slow move'
                assert s3.objects['prefix/Unrelated/probe.bin']['data'] == b'unrelated resident bytes'
                assert not any(event['operation']=='get' and
                               (event['key'].startswith('prefix/Slow/') or event['key'].startswith('prefix/Target/Slow moved/'))
                               for event in s3.events), 'slow move hydrated an uncached payload'
            metrics['slowObjects'] = len(expected)
            metrics['metadataDelaySeconds'] = args.metadata_delay
            metrics['copyDelaySeconds'] = args.copy_delay
            passed.append('delayed many-object folder move finishes without data loss or unrelated changes')
            if independent:
                local.command(['/sbin/umount', str(independent)])
                assert not local.is_mounted(independent)
        if args.finder:
            filesystem('''
import pathlib,sys
m=pathlib.Path(sys.argv[1]);(m/'Finder target').mkdir();(m/'Finder one').mkdir();(m/'Finder two').mkdir()
''', mount)
            # Finder receives only generated fixture paths, never user files.
            local.command(['/usr/bin/osascript', '-e', 'on run argv\n set firstItem to POSIX file (item 1 of argv) as alias\n set secondItem to POSIX file (item 2 of argv) as alias\n set destinationFolder to POSIX file (item 3 of argv) as alias\n tell application "Finder"\n move {firstItem, secondItem} to destinationFolder\n end tell\nend run', str(mount/'Finder one'), str(mount/'Finder two'), str(mount/'Finder target')], timeout=30)
            passed.append('Finder two-folder move')
        if s3:
            assert any(e['operation']=='copy' for e in s3.events)
            assert any(e['operation']=='delete' for e in s3.events)
            assert not any(e['operation']=='get' and (e['key'].endswith('/loose.bin') or e['key'].endswith('/uncached-large.bin')) for e in s3.events), 'move downloaded an uncached payload'
            assert any(e['operation']=='multipartCopy' for e in s3.events)
            passed.append('S3 server-side copy/delete without payload GET')
            # A denied delete must retain the verified destination and source.
            with s3.guard: s3.fail_delete = 'prefix/Target/loose.bin'
            result = subprocess.run([sys.executable, '-c', 'import os,sys;os.rename(sys.argv[1],sys.argv[2])', str(mount/'Target/loose.bin'), str(mount/'Target/recovered.bin')], timeout=20, capture_output=True)
            assert result.returncode != 0
            assert control('vfs/moves')['needsRecovery']
            # Retained recovery is terminal, not an endless NFS JUKEBOX retry.
            # A fresh destination lookup must fail promptly while its record is protected.
            filesystem('''
import errno,os,pathlib,sys,time
m=pathlib.Path(sys.argv[1]); started=time.monotonic()
try:
    os.stat(m/'Target/recovered.bin')
except OSError as error:
    assert error.errno==errno.EIO, error
else:
    raise AssertionError('unresolved destination was exposed')
assert time.monotonic()-started<3
assert (m/'Target/Album/keep').read_bytes()==b'keep sibling'
''', mount, timeout=5)
            passed.append('inactive recovery returns terminal I/O error without blocking unrelated reads or normal eject')
            with s3.guard:
                assert s3.objects['prefix/Target/loose.bin']['data'] == b'loose'
                assert s3.objects['prefix/Target/recovered.bin']['data'] == b'loose'
                s3.fail_delete = None
            # Deliberately crash only this owned synthetic worker after an uncertain
            # delete, then require the new process to discover the durable record.
            local.command(['/sbin/umount', str(mount)])
            assert not local.is_mounted(mount)
            worker.kill(); worker.wait(timeout=10)
            worker = subprocess.Popen(command, env=env, stdout=subprocess.DEVNULL, stderr=log)
            record.write_text(json.dumps({'pid': worker.pid, 'controlPort': rc, 'nfsPort': nfs, 'token': password}))
            record.chmod(0o600)
            local.until(ready)
            assert control('vfs/moves')['needsRecovery']
            control('vfs/moves', {'resume': True})
            local.until(lambda: not control('vfs/moves')['active'])
            assert not control('vfs/moves')['needsRecovery']
            with s3.guard:
                assert 'prefix/Target/loose.bin' not in s3.objects
                assert s3.objects['prefix/Target/recovered.bin']['data'] == b'loose'
            passed.append('denied delete retains both copies; authenticated recovery completes')
            passed.append('worker death and restart discovers and resumes durable move records')
            if args.concurrent:
                # Introduce a competing object after the worker's existence check,
                # immediately before R2 evaluates the signed destination condition.
                raced_source = 'prefix/Raced/test.bin'
                raced_target = 'prefix/Target/Raced/test.bin'
                with s3.guard:
                    s3.inject_copy_collision = raced_target
                raced = control('vfs/move', {'source':'Raced','destination':'Target/Raced','requestID':str(uuid.uuid4())})
                local.until(lambda: control('vfs/moves')['needsRecovery'])
                with s3.guard:
                    assert s3.objects[raced_source]['data']==b'Raced'
                    assert s3.objects[raced_target]['data']==b'concurrent unrelated owner'
                    del s3.objects[raced_target]  # release only the injected race in the synthetic provider
                control('vfs/moves', {'resume':True, 'id':raced['id']})
                local.until(lambda: not control('vfs/moves')['active'])
                assert not control('vfs/moves')['needsRecovery']
                with s3.guard:
                    assert raced_source not in s3.objects and s3.objects[raced_target]['data']==b'Raced'
                passed.append('R2 destination race preserved both owners and explicit recovery finished after the conflict cleared')

        else:
            assert (source/'Target/Moved Album/Sub/Résumé.wav').read_bytes()==b'original payload'*1024
            assert not (source/'Album').exists()
            passed.append('independent backend content and source absence')
        if local.is_mounted(mount): local.command(['/sbin/umount', str(mount)])
        assert not local.is_mounted(mount)
        local.until(lambda: not control('vfs/moves')['active'])
        local.until(lambda: all(control()['diskCache'][k]==0 for k in ('uploadsQueued','uploadsInProgress','erroredFiles')))
        worker.terminate(); worker.wait(timeout=10)
        success = True
    finally:
        safe = False
        # Preserve partial evidence on failure without presenting it as an overall pass.
        try:
            progress = root/'progress.json'
            progress.write_text(json.dumps({'passed': passed, 'metrics': metrics,
                'scope': 'Existing unrelated directory handles and optional independent native mount; same-mount rename parent-directory lookup may wait in macOS.'}, indent=2))
            progress.chmod(0o600)
        except OSError: pass
        if s3:
            s3.inventory_release.set(); s3.copy_release.set()
        for child in children:
            if child.poll() is None:
                child.terminate()
                try: child.wait(timeout=2)
                except subprocess.TimeoutExpired: pass
        try:
            for extra_mount in extra_mounts:
                if local.is_mounted(extra_mount): local.command(['/sbin/umount', str(extra_mount)])
            if local.is_mounted(mount): local.command(['/sbin/umount', str(mount)])
            if not local.is_mounted(mount):
                state = control('vfs/moves') if worker.poll() is None else None
                if state and (state['active'] or state['needsRecovery']): raise RuntimeError('unresolved move; preserve worker')
                if worker.poll() is None:
                    local.until(lambda: all(control()['diskCache'][k]==0 for k in ('uploadsQueued','uploadsInProgress','erroredFiles')))
                    worker.terminate(); worker.wait(timeout=10)
                safe = worker.poll() is not None
        except Exception: safe = False
        log.close()
        if s3 and safe: s3.shutdown(); s3.server_close()
        if success and safe:
            result = {'backendSHA256': hashlib.sha256(args.backend.read_bytes()).hexdigest(), 'passed': passed}
            if metrics: result['metrics'] = metrics
            if args.slow:
                result['scope'] = 'Existing unrelated directory handles and optional independent native mount; same-mount rename parent-directory lookup may wait in macOS.'
            shutil.rmtree(root); print(json.dumps(result, indent=2))
        else: print(f'Fixture retained at {root}; worker PID {worker.pid}. Never remove a mounted fixture.', file=sys.stderr)


if __name__ == '__main__': main()
