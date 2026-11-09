#!/usr/bin/env python3
"""Qualify the real owner process using generated data and private local storage.

Never reads a saved connection, mounts a volume, or touches user bucket objects.
Accepted local changes must survive process death before background publication.
"""
import argparse
import base64
import hashlib
import json
import math
import os
from pathlib import Path
import selectors
import socket
import struct
import subprocess
import sys
import tempfile
import time
import uuid
import platform

ROOT = Path(__file__).resolve().parent.parent


def timing_summary(samples):
    """Nearest-rank percentiles; keep count so smoke runs cannot imply a p99 study."""
    ordered = sorted(samples)
    if not ordered or any(not math.isfinite(value) or value < 0 for value in ordered):
        raise ValueError('Timing samples must be finite nonnegative durations.')
    return {'count': len(ordered), 'minimum': ordered[0], 'maximum': ordered[-1],
            **{name: ordered[max(0, math.ceil(len(ordered)*fraction)-1)]
               for name, fraction in [('p50', .5), ('p95', .95), ('p99', .99)]}}


def positive_samples(value):
    count = int(value)
    if not 1 <= count <= 10_000:
        raise argparse.ArgumentTypeError('Rename samples must be between 1 and 10000.')
    return count


def write_new_evidence(path, result):
    # Explicit output is new-only: never replace earlier qualification evidence.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump(result, stream, indent=2); stream.write('\n'); stream.flush(); os.fsync(stream.fileno())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--engine', type=Path, default=ROOT/'.build/debug/CloudDriveEngine')
    parser.add_argument('--managed', action='store_true')
    parser.add_argument('--rename-samples', type=positive_samples, default=1,
                        help='Repeated local folder rename samples (default: one smoke sample).')
    parser.add_argument('--output-json', type=Path, help='Write a new, private evidence file; existing files are refused.')
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix='namespace-engine-')); work.chmod(0o700)
    remote = work/'remote'; remote.mkdir(mode=0o700)
    state = work/'state'; state.mkdir(mode=0o700)
    mode = 'managed' if args.managed else 'compatible'
    payload = b'original synthetic audio bytes\n' * 128
    def seed(key, data):
        digest = hashlib.sha256(data).hexdigest()
        value = {'object': {'key': key, 'size': len(data), 'validator': '"'+digest+'"',
                            'checksum': digest, 'operationID': str(uuid.uuid4()), 'modifiedAt': 0},
                 'data': base64.b64encode(data).decode()}
        path = remote/(hashlib.sha256(key.encode()).hexdigest()+'.json')
        path.write_text(json.dumps(value)); path.chmod(0o600)
    seed('fixture/Album/track.bin', payload)
    seed('fixture/Album/Sub/other.bin', b'keep descendant')
    seed('fixture/Unrelated/keep.bin', b'keep unrelated')
    worker = None
    log = (work/'worker.log').open('wb'); os.chmod(work/'worker.log', 0o600)
    descriptor = None
    passed, metrics, rpc_durations = [], {}, {}
    def launch(read_only):
        nonlocal worker, descriptor
        session = str(uuid.uuid4())
        resource = Path('/tmp')/('clouddrive-'+str(os.getuid()))/session[:16]
        configuration = {'directory': state.as_uri(), 'binding': 'synthetic-qualified-'+mode,
                         'mode': mode, 'fixtureDirectory': remote.as_uri(),
                         'resourceDirectory': resource.as_uri(), 'sessionID': session, 'readOnly': read_only}
        worker = subprocess.Popen([str(args.engine.resolve()), '--serve'], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=log)
        worker.stdin.write(json.dumps(configuration).encode()); worker.stdin.close()
        selector = selectors.DefaultSelector(); selector.register(worker.stdout, selectors.EVENT_READ)
        try:
            if not selector.select(15): raise RuntimeError('Owner did not announce readiness; inspect retained worker log')
            line = worker.stdout.readline(16_385)
            if not line or len(line) > 16_384: raise RuntimeError('Owner exited before announcing its descriptor')
            descriptor = json.loads(line)
        finally: selector.close()
        assert descriptor['binding'] == configuration['binding'] and descriptor['sessionID'].lower() == session.lower()
        deadline = time.monotonic()+5
        while time.monotonic() < deadline:
            try: return rpc('volume')
            except (OSError, RuntimeError): time.sleep(.05)
        raise RuntimeError('Owner socket did not become ready')
    def rpc(operation, **fields):
        started = time.monotonic()
        request = dict(protocolVersion=1, requestID=str(uuid.uuid4()), authToken=descriptor['token'], operation=operation)
        request.update(fields)
        body = json.dumps(request).encode()
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(20); client.connect(descriptor['socketPath'])
            client.sendall(struct.pack('>I', len(body))+body)
            def receive(count):
                result = b''
                while len(result) < count:
                    chunk = client.recv(count-len(result))
                    if not chunk: raise RuntimeError('Owner rejected/closed the request')
                    result += chunk
                return result
            size = struct.unpack('>I', receive(4))[0]
            assert 0 < size <= 4*1024*1024
            response = json.loads(receive(size))
        assert response['requestID'].lower() == request['requestID'].lower()
        if response.get('error'): raise RuntimeError('Filesystem errno '+str(response['error']['errno'])+' '+str(response.get('attributes',{}).get('failureKind','')))
        rpc_durations.setdefault(operation, []).append(time.monotonic()-started)
        return response
    def child(parent, name): return rpc('lookup', parentID=parent, name=name)['node']
    def read(node, handle=None):
        fields = {'nodeID': node['id'], 'offset': 0, 'length': max(1, node['size'])}
        if handle: fields['handleID'] = handle
        return base64.b64decode(rpc('read', **fields).get('data', ''))
    def status(): return json.loads(base64.b64decode(rpc('status')['data']))
    try:
        root_id = launch(True)['volume']['rootID']
        try: rpc('create', parentID=root_id, name='forbidden', kind='file')
        except RuntimeError as error: assert '30' in str(error)  # EROFS
        else: raise AssertionError('Read-only owner accepted a mutation')
        progress = json.loads(base64.b64decode(rpc('import')['data']))
        assert progress['complete'] and progress['objects'] == 3
        if args.managed: rpc('seedManaged')
        rpc('enableWrites')
        passed.append('read-only import and explicit mutation admission')
        album = child(root_id, 'Album'); track = child(album['id'], 'track.bin')
        handle = rpc('open', nodeID=track['id'])['handleID']
        started = time.monotonic()
        renamed = rpc('rename', nodeID=album['id'], destinationParentID=root_id, destinationName='Moved')['node']
        metrics['renameCallbackSeconds'] = time.monotonic()-started
        assert metrics['renameCallbackSeconds'] < .250
        assert renamed['id'] == album['id'] and renamed['inode'] == album['inode']
        assert child(child(root_id, 'Moved')['id'], 'track.bin')['id'] == track['id']
        rename_samples = [metrics['renameCallbackSeconds']]
        for index in range(1, args.rename_samples):
            started = time.monotonic()
            sample = rpc('rename', nodeID=album['id'], destinationParentID=root_id,
                         destinationName='Measured-'+str(index))['node']
            rename_samples.append(time.monotonic()-started)
            assert sample['id'] == album['id'] and sample['inode'] == album['inode']
        metrics['renameRoundTripSeconds'] = timing_summary(rename_samples)
        if args.rename_samples > 1:
            rpc('rename', nodeID=album['id'], destinationParentID=root_id, destinationName='Moved')
        # This is a tiny local fixture, not a Finder or 100,000-descendant benchmark.
        assert metrics['renameRoundTripSeconds']['p99'] < .250
        assert read(track, handle) == payload
        assert read(child(child(root_id, 'Unrelated')['id'], 'keep.bin')) == b'keep unrelated'
        passed.append('local folder rename, stable IDs, old handles and unrelated reads')
        written = rpc('write', nodeID=track['id'], handleID=handle, offset=0, data=base64.b64encode(b'NEW').decode())['node']
        assert read(written, handle) == b'NEW'+payload[3:]
        rpc('sync')
        # This is only the owned synthetic worker, with no mounted filesystem.
        worker.kill(); worker.wait(timeout=5)
        root_id = launch(False)['volume']['rootID']
        recovered = child(child(root_id, 'Moved')['id'], 'track.bin')
        assert recovered['id'] == track['id'] and read(recovered) == b'NEW'+payload[3:]
        passed.append('acknowledged namespace and staged bytes survive worker death')
        changed = rpc('open', nodeID=recovered['id'])['handleID']
        rpc('remove', nodeID=recovered['id'])
        unlinked = rpc('write', nodeID=recovered['id'], handleID=changed, offset=0, data=base64.b64encode(b'OLD').decode())['node']
        assert read(unlinked, changed).startswith(b'OLD')
        rpc('close', nodeID=recovered['id'], handleID=changed)
        passed.append('unlinked open content remains readable and writable')
        deadline = time.monotonic()+30
        while time.monotonic() < deadline:
            current = status()
            if current['pending'] == 0: break
            if current['attention']: rpc('resume')
            time.sleep(.1)
        else: raise RuntimeError('Synthetic cloud work did not finish; retained state='+str(work))
        rpc('detach'); assert rpc('prepareStop')['attributes']['safeToStop'] == 'true'
        worker.terminate(); worker.wait(timeout=5)
        passed.append('background publication, detached quiescence and owned stop')
        result = {'schema': 2, 'status': 'pass', 'mode': mode, 'engineSHA256': hashlib.sha256(args.engine.read_bytes()).hexdigest(),
                  'passed': passed, 'metrics': metrics, 'scope': 'Synthetic remote; no Finder mount, live R2 or power-loss qualification.'}
        result['host'] = {'os': platform.system(), 'release': platform.release(), 'architecture': platform.machine(),
                          'macOS': platform.mac_ver()[0], 'python': platform.python_version()}
        result['rpcSuccessfulRoundTripSeconds'] = {name: timing_summary(values) for name, values in rpc_durations.items()}
        result['fixture'] = {'objects': 3, 'payloadSHA256': hashlib.sha256(payload).hexdigest(),
                             'sourceSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
        result['measurementLimitations'] = ['Round trips include IPC and scheduling; no isolated callback timer.',
                                            'Only successful RPC durations are summarized; failures abort the run.',
                                            'One rename sample is a smoke check, not percentile qualification.']
        (work/'result.json').write_text(json.dumps(result, indent=2)); (work/'result.json').chmod(0o600)
        if args.output_json: write_new_evidence(args.output_json, result)
        print(json.dumps(result, indent=2))
        print('Evidence:', work)
    except Exception as error:
        failure = {'schema': 2, 'status': 'fail', 'mode': mode, 'passed': passed, 'metrics': metrics,
                   'engineSHA256': hashlib.sha256(args.engine.read_bytes()).hexdigest(),
                   'errorType': type(error).__name__, 'error': str(error),
                   'rpcSuccessfulRoundTripSeconds': {name: timing_summary(values) for name, values in rpc_durations.items()},
                   'scope': 'Synthetic remote only; retained fixture state may explain the failure.'}
        write_new_evidence(work/'failure.json', failure)
        if args.output_json and not args.output_json.exists(): write_new_evidence(args.output_json, failure)
        print('Failed qualification; retained evidence:', work, file=sys.stderr)
        raise
    finally:
        if worker and worker.poll() is None:
            worker.terminate()
            try: worker.wait(timeout=5)
            except subprocess.TimeoutExpired: pass
        log.close()


if __name__ == '__main__': main()
