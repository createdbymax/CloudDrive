#!/usr/bin/env python3
"""Bounded, disposable macOS Finder/NFS qualification. Never uses R2 credentials.

Artifacts are removed only after success, confirmed unmount and worker exit.
Every failure retains the fixture and its private control record for diagnosis.
"""
import base64
import json
import os
import pathlib
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent


def port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def command(args, timeout=20):
    """No unbounded wait, including after a helper becomes stuck in a syscall."""
    process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        output, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        try:
            process.communicate(timeout=1)
        except subprocess.TimeoutExpired:
            pass
        raise RuntimeError(f'helper exceeded {timeout}s; fixture retained (PID {process.pid})')
    if process.returncode:
        raise RuntimeError(f'helper failed with status {process.returncode}; fixture retained')
    return output.decode()


def is_mounted(path):
    # Reading the mount table does not traverse a potentially stalled NFS path.
    mounts = command(['/sbin/mount'], timeout=3)
    return any(f' on {path} (' in line for line in mounts.splitlines())


def until(fn, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            if fn():
                return
        except (OSError, ValueError, urllib.error.URLError):
            pass
        time.sleep(.2)
    raise RuntimeError('qualification deadline exceeded; fixture retained')


def filesystem(code, *args):
    # Mounted I/O belongs in a separate process so the harness remains responsive.
    command([sys.executable, '-c', code, *map(str, args)], timeout=20)


def main():
    root = pathlib.Path(tempfile.mkdtemp(prefix='clouddrive-qualification-')).resolve()
    root.chmod(0o700)
    source, mount = root / 'source', root / 'mount'
    source.mkdir(); mount.mkdir()
    nfs, rc = port(), port()
    while rc == nfs:
        rc = port()
    password = os.urandom(32).hex()
    # Explicit environment prevents ambient backend/control flags affecting this fixture.
    env = {k: os.environ[k] for k in ('PATH', 'HOME', 'TMPDIR', 'LANG') if k in os.environ}
    env.update(RCLONE_RC_USER='fixture', RCLONE_RC_PASS=password)
    worker = subprocess.Popen([
        str(ROOT / 'build/backend/rclone'), 'serve', 'nfs', str(source),
        '--addr', f'127.0.0.1:{nfs}', '--config', '/dev/null',
        '--vfs-cache-mode', 'full', '--vfs-write-back', '1s',
        '--cache-dir', str(root / 'cache'), '--rc', '--rc-addr', f'127.0.0.1:{rc}'
    ], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    record = root / 'fixture-control.json'
    fd = os.open(record, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as handle:
        json.dump({'pid': worker.pid, 'controlPort': rc, 'nfsPort': nfs, 'token': password}, handle)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    passed = []
    success = False

    def control(token=password):
        request = urllib.request.Request(
            f'http://127.0.0.1:{rc}/vfs/stats', data=b'{}',
            headers={'Content-Type': 'application/json', 'Authorization': 'Basic ' +
                     base64.b64encode(f'fixture:{token}'.encode()).decode()})
        with opener.open(request, timeout=2) as response:
            return json.load(response)

    def queue_idle():
        disk = control()['diskCache']
        values = [disk[k] for k in ('uploadsQueued', 'uploadsInProgress', 'erroredFiles')]
        if any(type(v) is not int or v < 0 for v in values):
            raise RuntimeError('invalid upload status')
        return all(v == 0 for v in values)

    def mount_fixture():
        if is_mounted(mount):
            raise RuntimeError('fixture path is already mounted; refusing to overlay it')
        command(['/sbin/mount_nfs', '-o',
                 f'port={nfs},mountport={nfs},tcp,vers=3,nolocks,nodev,nosuid',
                 '127.0.0.1:/', str(mount)])
        if not is_mounted(mount):
            raise RuntimeError('mount helper succeeded without a visible mount')

    try:
        until(control)
        assert worker.poll() is None and not is_mounted(mount)
        passed.append('worker alive before mount')
        try:
            control('wrong-token')
        except urllib.error.HTTPError as error:
            assert error.code == 401
        else:
            raise AssertionError('wrong control token accepted')
        passed.append('wrong control token rejected')
        stats = control()
        assert stats['fs'].rstrip('/') == str(source)
        assert stats['diskCache']['path'].startswith(str(root / 'cache') + '/')
        passed.append('authenticated backend/cache identity')
        mount_fixture(); passed.append('native mount')
        filesystem('''
import hashlib, os, pathlib, sys
m=pathlib.Path(sys.argv[1]); s=pathlib.Path(sys.argv[2])
payload=os.urandom(8*1024*1024); (m/'folder').mkdir()
p=m/'folder'/'Résumé.bin'; p.write_bytes(payload)
assert hashlib.sha256(p.read_bytes()).digest()==hashlib.sha256(payload).digest()
(s/'expected.sha256').write_text(hashlib.sha256(payload).hexdigest())
''', mount, root)
        until(lambda: hashlib_matches(source / 'folder' / 'Résumé.bin', root / 'expected.sha256'))
        passed += ['8 MiB independent backend checksum', 'Unicode filename']
        filesystem('''
import os,pathlib,sys
m=pathlib.Path(sys.argv[1]); (m/'folder'/'Résumé.bin').rename(m/'folder'/'renamed.bin')
(m/'folder'/'temp.bin').write_bytes(b'replacement')
os.replace(m/'folder'/'temp.bin',m/'folder'/'renamed.bin')
''', mount)
        until(lambda: (source / 'folder' / 'renamed.bin').read_bytes() == b'replacement')
        passed += ['rename', 'atomic replacement']
        command(['/sbin/umount', str(mount)])
        assert not is_mounted(mount) and worker.poll() is None
        until(queue_idle)
        passed += ['worker alive with mount missing', 'authenticated queue drain after eject']
        mount_fixture()
        filesystem('''
import pathlib,sys
p=pathlib.Path(sys.argv[1])/'folder'/'renamed.bin'
assert p.read_bytes()==b'replacement'
p.unlink()
''', mount)
        until(lambda: not (source / 'folder' / 'renamed.bin').exists())
        passed += ['remount read', 'delete']
        command(['/sbin/umount', str(mount)])
        until(queue_idle)
        worker.terminate(); worker.wait(timeout=10)
        assert worker.poll() is not None
        try:
            control()
        except (OSError, urllib.error.URLError):
            pass
        else:
            raise AssertionError('dead worker still answered control request')
        passed += ['worker exit confirmed', 'dead worker control unavailable']
        success = True
    finally:
        # Never remove a mounted directory, even if a helper failed or timed out.
        safe_to_clean = False
        try:
            if is_mounted(mount):
                command(['/sbin/umount', str(mount)])
            if not is_mounted(mount):
                if worker.poll() is None:
                    until(queue_idle, seconds=10)
                    worker.terminate(); worker.wait(timeout=10)
                safe_to_clean = worker.poll() is not None
        except Exception:
            safe_to_clean = False
        if success and safe_to_clean:
            shutil.rmtree(root)
            print(json.dumps({'passed': passed + ['safe fixture cleanup']}, indent=2))
        else:
            print(f'Fixture retained at {root}; worker PID {worker.pid}. Do not recursively remove a mounted fixture.', file=sys.stderr)
            if success:
                raise RuntimeError('checks passed but safe cleanup was not confirmed')


def hashlib_matches(path, digest_path):
    import hashlib
    return hashlib.sha256(path.read_bytes()).hexdigest() == digest_path.read_text()


if __name__ == '__main__':
    main()
