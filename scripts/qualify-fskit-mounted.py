#!/usr/bin/env python3
"""Exercise the installed native FSKit extension on an isolated synthetic remote.

Requires --mount-fixture acknowledgement. Never accesses saved cloud credentials.
Retains all evidence. Never force-unmounts or stops an owner while mounted.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import platform
import selectors
import socket
import struct
import subprocess
import sys
import tempfile
import time
import uuid
from urllib.parse import urlparse, unquote

ROOT = Path(__file__).resolve().parent.parent


def save(path, value):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n'); stream.flush(); os.fsync(stream.fileno())


def mounts_at(path):
    output = subprocess.run(['/sbin/mount'], capture_output=True, text=True, timeout=5, check=True).stdout
    return [line for line in output.splitlines() if ' on '+str(path)+' (' in line]


def owned_mount(entries, resource, mountpoint):
    if len(entries) != 1: return False
    source, details = entries[0].split(' on '+str(mountpoint)+' (', 1)
    if details.split(',', 1)[0].rstrip(')') not in ('clouddrive', 'fskit'): return False
    if source.startswith('file:'):
        url = urlparse(source)
        if url.netloc not in ('', 'localhost') or url.query or url.fragment: return False
        source = unquote(url.path)
    if not source.startswith('/'): return False
    return Path(source).resolve() == resource.resolve()


def exercise(mountpoint, output, check_replacement=False):
    # Executed in a separate process: an unresponsive filesystem cannot hang the controller.
    passed = []
    payload = bytes(range(256)) * 8192 + b'native FSKit synthetic tail'
    folder = mountpoint/'Created'; folder.mkdir()
    path = folder/'payload.bin'
    with path.open('xb', buffering=0) as stream:
        view = memoryview(payload)
        while view:
            count = stream.write(view)
            if not count: raise RuntimeError('Short zero write')
            view = view[count:]
        os.fsync(stream.fileno())
    if path.read_bytes() != payload: raise RuntimeError('Initial content mismatch')
    passed.append('native mkdir, create, write, fsync, read and SHA256 content')
    before = path.stat()
    with path.open('r+b', buffering=0) as handle:
        started = time.monotonic()
        folder.rename(mountpoint/'Moved')
        rename_seconds = time.monotonic()-started
        moved = mountpoint/'Moved'/'payload.bin'
        if moved.stat().st_ino != before.st_ino: raise RuntimeError('Rename changed inode')
        if handle.read() != payload: raise RuntimeError('Open handle changed after folder rename')
        if moved.read_bytes() != payload: raise RuntimeError('Renamed content mismatch')
        passed.append('folder rename retains inode, content and open handle')
        moved.unlink()
        if moved.exists(): raise RuntimeError('Unlink left namespace entry')
        handle.seek(0)
        if handle.read() != payload: raise RuntimeError('Unlinked open handle lost content')
        handle.seek(0); handle.write(b'NEW'); os.fsync(handle.fileno()); handle.seek(0)
        if handle.read() != b'NEW'+payload[3:]: raise RuntimeError('Unlinked handle write mismatch')
        passed.append('unlink keeps open file readable and writable until close')
    (mountpoint/'Moved').rmdir()
    if (mountpoint/'seed.bin').read_bytes() != b'untouched synthetic seed':
        raise RuntimeError('Unrelated imported content changed')
    passed.append('rmdir and unrelated imported file read')
    if check_replacement:
        # The owning harness paused publication before spawning this process.
        from concurrent.futures import ThreadPoolExecutor
        from threading import Barrier
        destination = mountpoint/'Parallel destination'
        destination.mkdir()
        folders = [mountpoint/name for name in ('Parallel A', 'Parallel B')]
        for source in folders:
            source.mkdir()
            (source/'payload').write_bytes(source.name.encode())
        barrier = Barrier(len(folders))
        def move_folder(source):
            barrier.wait(timeout=5)
            source.rename(destination/source.name)
            return (destination/source.name/'payload').read_bytes()
        with ThreadPoolExecutor(max_workers=2) as pool:
            contents = list(pool.map(move_folder, folders))
        if contents != [source.name.encode() for source in folders] or any(source.exists() for source in folders):
            raise RuntimeError('Concurrent moves failed to preserve folder contents')
        passed.append('two concurrent native moves to one parent acknowledged while cloud publication was paused')
        target = mountpoint/'editor-saved.bin'
        draft = mountpoint/'editor-draft.bin'
        with target.open('x+b', buffering=0) as original, draft.open('x+b', buffering=0) as updated:
            original.write(b'original bytes'); os.fsync(original.fileno())
            updated.write(b'new editor bytes'); os.fsync(updated.fileno())
            draft_inode = os.fstat(updated.fileno()).st_ino
            os.replace(draft, target)
            if draft.exists() or target.stat().st_ino != draft_inode or target.read_bytes() != b'new editor bytes':
                raise RuntimeError('Atomic replacement did not publish the source at the existing name')
            original.seek(0); updated.seek(0)
            if original.read() != b'original bytes' or updated.read() != b'new editor bytes':
                raise RuntimeError('Atomic replacement lost an existing open file description')
            original.seek(0); original.write(b'OLD'); os.fsync(original.fileno())
            if target.read_bytes() != b'new editor bytes': raise RuntimeError('Retired handle changed the replacement')
        passed.append('atomic editor save over unpublished destination preserves both open file descriptions')
    save(output, {'passed': passed, 'bytes': len(payload), 'payloadSHA256': hashlib.sha256(payload).hexdigest(),
                  'folderRenameSeconds': rename_seconds})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--engine', type=Path, default=Path('/Applications/CloudDrive.app/Contents/Resources/CloudDriveEngine'))
    parser.add_argument('--mount-fixture', action='store_true', help='Explicitly allow a new isolated native mount.')
    parser.add_argument('--check-replacement', action='store_true', help='Exercise atomic replacement while background publication is paused.')
    parser.add_argument('--check-availability', action='store_true', help='Verify native read-only availability xattr through pin/free lifecycle.')
    parser.add_argument('--check-native-xattrs', action='store_true', help='Round-trip Finder tags on a fresh managed item and verify the owner, not an AppleDouble file, persisted them.')
    parser.add_argument('--finder-checkpoint', action='store_true', help='Wait up to 120 seconds for an explicit observed Finder acknowledgement.')
    parser.add_argument('--mode', choices=['managed', 'compatible'], default='managed')
    parser.add_argument('--output-json', type=Path, help='New evidence file only; never replaces an existing file.')
    parser.add_argument('--exercise', type=Path, help=argparse.SUPPRESS)
    parser.add_argument('--exercise-output', type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.exercise:
        exercise(args.exercise, args.exercise_output, args.check_replacement); return 0
    if not args.mount_fixture: parser.error('--mount-fixture is required; this command creates an isolated native mount')
    if sys.platform != 'darwin': parser.error('Native FSKit requires macOS')
    if args.output_json and args.output_json.exists(): parser.error('Evidence output already exists')
    engine = args.engine.resolve(strict=True)
    work = Path(tempfile.mkdtemp(prefix='clouddrive-fskit-')).resolve(); work.chmod(0o700)
    remote, state, mountpoint = [work/name for name in ('remote', 'state', 'mount')]
    for path in (remote, state, mountpoint): path.mkdir(mode=0o700)
    session = str(uuid.uuid4())
    # Ask the signed engine for its entitled container; don't infer container paths.
    try:
        query = subprocess.run([str(engine), '--resource-base'], capture_output=True, text=True, timeout=10)
        if query.returncode:
            raise RuntimeError('Signed engine resource-base query failed with exit '+str(query.returncode)+': '+query.stderr[-2000:])
        base = Path(query.stdout.strip())
        if not base.is_absolute(): raise RuntimeError('Engine returned invalid resource base')
        resource = base/session[:16]
    except Exception as error:
        failure = {'schema': 1, 'status': 'fail', 'stage': 'signed-engine-resource-base',
                   'error': type(error).__name__+': '+str(error), 'evidenceDirectory': str(work),
                   'engineSHA256': hashlib.sha256(engine.read_bytes()).hexdigest(),
                   'scope': 'Preflight failed; no filesystem mount or owner was started.',
                   'ownerRetained': False, 'mountMayRemain': False}
        save(work/'result.json', failure)
        if args.output_json: save(args.output_json, failure)
        print(json.dumps(failure, indent=2)); return 1
    config = {'directory': state.as_uri(), 'binding': 'native-synthetic-'+session, 'mode': args.mode,
              'fixtureDirectory': remote.as_uri(), 'resourceDirectory': resource.as_uri(),
              'sessionID': session, 'readOnly': True}
    data = b'untouched synthetic seed'; key = 'fixture/seed.bin'; digest = hashlib.sha256(data).hexdigest()
    save(remote/(hashlib.sha256(key.encode()).hexdigest()+'.json'),
         {'object': {'key': key, 'size': len(data), 'validator': '"'+digest+'"', 'checksum': digest,
                     'operationID': str(uuid.uuid4()), 'modifiedAt': 0}, 'data': base64.b64encode(data).decode()})
    result = {'schema': 1, 'status': 'fail', 'mode': args.mode, 'evidenceDirectory': str(work),
              'engineSHA256': hashlib.sha256(engine.read_bytes()).hexdigest(),
              'scriptSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              'host': {'macOS': platform.mac_ver()[0], 'architecture': platform.machine()},
              'scope': 'Actual native FSKit mount and POSIX filesystem operations; synthetic local remote only.',
              'limitations': ['Not live R2, power-loss, editor-save or performance qualification.',
                               'Finder coverage limited to explicitly recorded external observations.' if args.finder_checkpoint else 'No Finder UI qualification.'], 'passed': []}
    worker = None; descriptor = None; mounted = False; identity = None
    log = (work/'owner.log').open('xb'); os.chmod(work/'owner.log', 0o600)

    def rpc(operation, **fields):
        request = {'protocolVersion': 1, 'requestID': str(uuid.uuid4()), 'authToken': descriptor['token'], 'operation': operation}
        request.update(fields)
        body = json.dumps(request).encode()
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(10); client.connect(descriptor['socketPath']); client.sendall(struct.pack('>I', len(body))+body)
            def receive(count):
                value = b''
                while len(value) < count:
                    chunk = client.recv(count-len(value))
                    if not chunk: raise RuntimeError('Owner closed response')
                    value += chunk
                return value
            size = struct.unpack('>I', receive(4))[0]
            if not 0 < size <= 4*1024*1024: raise RuntimeError('Invalid response size')
            response = json.loads(receive(size))
        if response['requestID'].lower() != request['requestID'].lower(): raise RuntimeError('Response identity mismatch')
        if response.get('error'): raise RuntimeError('Owner error: '+str(response['error']))
        return response

    try:
        worker = subprocess.Popen([str(engine), '--serve'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=log, start_new_session=True)
        result['ownerPID'] = worker.pid
        worker.stdin.write(json.dumps(config).encode()); worker.stdin.close()
        with selectors.DefaultSelector() as selector:
            selector.register(worker.stdout, selectors.EVENT_READ)
            if not selector.select(15): raise RuntimeError('Owner readiness timeout')
            # Owner emits one bounded descriptor line. Read nonblocking to bound partial output too.
            os.set_blocking(worker.stdout.fileno(), False)
            raw = b''; deadline = time.monotonic()+5
            while b'\n' not in raw and time.monotonic() < deadline:
                raw += os.read(worker.stdout.fileno(), 16385-len(raw)) if selector.select(.1) else b''
                if len(raw) > 16384: raise RuntimeError('Oversize descriptor')
            if b'\n' not in raw: raise RuntimeError('Incomplete descriptor')
            descriptor = json.loads(raw.split(b'\n')[0])
        if descriptor['binding'] != config['binding'] or descriptor['sessionID'].lower() != session.lower():
            raise RuntimeError('Owner identity mismatch')
        save(work/'owner-descriptor.json', descriptor)
        progress = json.loads(base64.b64decode(rpc('import')['data']))
        if not progress['complete'] or progress['objects'] != 1: raise RuntimeError('Synthetic import incomplete')
        if args.mode == 'managed': rpc('seedManaged')
        rpc('enableWrites')
        if mounts_at(mountpoint): raise RuntimeError('Unexpected existing mount')
        command = subprocess.run(['/sbin/mount', '-F', '-t', 'clouddrive', str(resource), str(mountpoint)],
                                 capture_output=True, text=True, timeout=25)
        result['mountCommand'] = {'exitCode': command.returncode, 'stdout': command.stdout, 'stderr': command.stderr}
        entries = mounts_at(mountpoint); mounted = bool(entries)
        if not owned_mount(entries, resource, mountpoint):
            raise RuntimeError('Native mount identity not confirmed')
        identity = entries[0]; result['mountIdentity'] = identity
        if command.returncode: raise RuntimeError('Mount command failed')
        result['passed'].append('installed FSKit extension mounted authenticated isolated owner resource')
        if args.check_availability:
            root_id = rpc('volume')['volume']['rootID']
            seed_id = rpc('lookup', parentID=root_id, name='seed.bin')['node']['id']
            def availability():
                # macOS CPython does not expose os.getxattr. The system xattr
                # tool's -s addresses the link itself rather than following it.
                probe = subprocess.run(['/usr/bin/xattr', '-p', '-s', 'com.clouddrive.availability',
                    str(mountpoint/'seed.bin')], capture_output=True, text=True, timeout=10, check=True)
                return probe.stdout.strip()
            if availability() != 'remoteOnly' or availability() != 'remoteOnly':
                raise RuntimeError('Availability reads did not preserve uncached seed state')
            rpc('pin', nodeID=seed_id)
            deadline = time.monotonic()+20
            while time.monotonic() < deadline:
                progress = json.loads(base64.b64decode(rpc('pinStatus')['data']))
                matches = [item for item in progress if item['nodeID'].lower() == seed_id.lower()]
                if matches and matches[0]['state'] == 'attention': raise RuntimeError('Synthetic pin requires attention')
                if matches and matches[0]['state'] == 'complete': break
                time.sleep(.1)
            else: raise RuntimeError('Synthetic pin did not complete')
            if availability() != 'availableOffline': raise RuntimeError('Verified pin lacks native offline state')
            rpc('unpin', nodeID=seed_id); rpc('freeLocalSpace', nodeID=seed_id)
            if availability() != 'remoteOnly': raise RuntimeError('Freed cache incorrectly advertised offline')
            result['passed'].append('native computed availability: repeated remoteOnly, pinned availableOffline, freed remoteOnly')
        if args.check_native_xattrs:
            if args.mode != 'managed': raise RuntimeError('The native metadata test requires a managed fixture')
            import plistlib
            name = 'com.apple.metadata:_kMDItemUserTags'
            tag = plistlib.dumps(['Fixture Tag\n6'], fmt=plistlib.FMT_BINARY)
            f = mountpoint/'tagged.txt'; f.write_bytes(b'tagged bytes')
            def attr(*args):
                return subprocess.run(['/usr/bin/xattr', *map(str, args)], check=True, capture_output=True, text=True, timeout=10).stdout
            attr('-wx', name, tag.hex(), f)
            moved = mountpoint/'renamed-tagged.txt'; f.rename(moved)
            if bytes.fromhex(attr('-px', name, moved)) != tag: raise RuntimeError('Finder tag bytes changed after rename')
            root_id = rpc('volume')['volume']['rootID']
            node = rpc('lookup', parentID=root_id, name=moved.name)['node']
            if base64.b64decode((node.get('xattrs') or {}).get(name, '')) != tag:
                raise RuntimeError('Tag was not stored on the native item')
            if (mountpoint/('._'+moved.name)).exists(): raise RuntimeError('Tag unexpectedly used AppleDouble')
            attr('-d', name, moved)
            if name in attr(moved).splitlines(): raise RuntimeError('Native attribute removal failed')
            result['passed'].append('native Finder tag bytes persisted on stable ID across rename and removal without AppleDouble')
        if args.check_replacement: rpc('pause')
        child_args = [sys.executable, str(Path(__file__).resolve()), '--exercise', str(mountpoint),
                      '--exercise-output', str(work/'filesystem.json')]
        if args.check_replacement: child_args.append('--check-replacement')
        child = subprocess.run(child_args, capture_output=True, text=True, timeout=45)
        if args.check_replacement: rpc('resume')
        result['filesystemExitCode'] = child.returncode
        if child.returncode: raise RuntimeError('Filesystem exercise failed: '+child.stderr[-4000:])
        exercise_result = json.loads((work/'filesystem.json').read_text())
        result['filesystem'] = exercise_result; result['passed'] += exercise_result['passed']
        if args.finder_checkpoint:
            acknowledgement = work/'finder-observed.json'
            print(json.dumps({'event': 'finderCheckpoint', 'mountpoint': str(mountpoint),
                              'ackPath': str(acknowledgement), 'timeoutSeconds': 120}), flush=True)
            deadline = time.monotonic()+120
            while time.monotonic() < deadline:
                if acknowledgement.exists():
                    fd = os.open(acknowledgement, os.O_RDONLY | os.O_NOFOLLOW)
                    with os.fdopen(fd) as stream: observed = json.loads(stream.read(16385))
                    if observed.get('observed') is not True: raise RuntimeError('Finder checkpoint was not confirmed as observed')
                    result['finderObservation'] = observed
                    result['passed'].append('external observer confirmed Finder checkpoint actions')
                    break
                if worker.poll() is not None: raise RuntimeError('Owner stopped during Finder checkpoint')
                time.sleep(.2)
            else: raise RuntimeError('Finder observation checkpoint timed out')
        deadline = time.monotonic()+30
        while time.monotonic() < deadline:
            status = json.loads(base64.b64decode(rpc('status')['data']))
            if status['attention']: raise RuntimeError('Publication requires attention')
            if status['pending'] == 0: break
            time.sleep(.2)
        else: raise RuntimeError('Synthetic background publication timeout')
        result['passed'].append('synthetic background publication drained')
        if args.check_replacement and args.mode == 'compatible':
            name = hashlib.sha256(b'fixture/editor-saved.bin').hexdigest()+'.json'
            actual = json.loads((remote/name).read_text())
            if base64.b64decode(actual['data']) != b'new editor bytes': raise RuntimeError('Published replacement bytes differ')
            result['passed'].append('compatible ordinary key contains exact replacement bytes')
        result['status'] = 'pass'
    except Exception as error:
        result['error'] = type(error).__name__+': '+str(error)
    finally:
        # Recheck even after mount timeout: the helper may have mounted before timing out.
        try:
            entries = mounts_at(mountpoint); mounted = bool(entries)
            if mounted:
                if not owned_mount(entries, resource, mountpoint):
                    raise RuntimeError('Refusing unmount of unexpected identity')
                unmount = subprocess.run(['/sbin/umount', str(mountpoint)], capture_output=True, text=True, timeout=15)
                result['unmount'] = {'exitCode': unmount.returncode, 'stderr': unmount.stderr}
                mounted = bool(mounts_at(mountpoint))
                if unmount.returncode or mounted: raise RuntimeError('Normal unmount failed; owner retained')
                result['passed'].append('normal native unmount confirmed')
            if worker and worker.poll() is None and not mounted:
                if descriptor:
                    rpc('detach')
                    if rpc('prepareStop').get('attributes', {}).get('safeToStop') != 'true':
                        raise RuntimeError('Owner is not safe to stop; retained')
                worker.terminate(); worker.wait(timeout=5)
        except Exception as error:
            result['status'] = 'fail'; result['cleanupError'] = type(error).__name__+': '+str(error)
        result['ownerRetained'] = worker is not None and worker.poll() is None
        result['mountMayRemain'] = mounted
        log.close()
        save(work/'result.json', result)
        if args.output_json: save(args.output_json, result)
        print(json.dumps(result, indent=2))
    return 0 if result['status'] == 'pass' else 1


if __name__ == '__main__': sys.exit(main())
