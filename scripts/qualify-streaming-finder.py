#!/usr/bin/env python3
"""Operator-driven native Finder copy into an isolated streaming NFS experiment.

No UI automation, owner state, credentials or provider is used. Native Finder must
copy the printed synthetic source to the printed mount, then the operator creates
the acknowledgement file. Publication is explicit and occurs only after normal
unmount. Failed fixtures remain for diagnosis; mounted trees are never removed.
"""
import argparse
import hashlib
import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('local', ROOT/'scripts/qualify-local.py')
local = importlib.util.module_from_spec(spec)
spec.loader.exec_module(local)
MiB = 1024 * 1024
TARGET = 'finder-fixture.dat'


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as handle:
        for block in iter(lambda: handle.read(MiB), b''): h.update(block)
    return h.hexdigest()


def coverage(extents, size):
    """Unique accepted target ranges; preallocation and repeated writes add no progress."""
    ranges = []
    for extent in extents:
        start, length = extent['Offset'], extent['Length']
        assert type(start) is int and type(length) is int and start >= 0 and 0 < length <= MiB
        ranges.append((min(start, size), min(start + length, size)))
    merged = []
    for start, end in sorted(ranges):
        if merged and start <= merged[-1][1]: merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else: merged.append((start, end))
    return sum(end - start for start, end in merged)


def allocated_tree(root):
    total = 0
    for path in root.iterdir():
        try:
            st = path.lstat()
            if path.is_file() and not path.is_symlink(): total += st.st_blocks * 512
        except FileNotFoundError: pass  # Atomic journal rename while sampling.
    return total


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--engine', type=pathlib.Path, default=ROOT/'experiments/streaming-nfs/bin/streaming-nfs')
    parser.add_argument('--report', type=pathlib.Path, default=pathlib.Path('/tmp/clouddrive-streaming-finder-report.json'))
    args = parser.parse_args()
    engine_binary = args.engine.resolve(strict=True)
    root = pathlib.Path(tempfile.mkdtemp(prefix='clouddrive-streaming-finder-')).resolve()
    root.chmod(0o700)
    source, mount, backend, state = (root/name for name in ('source', 'mount', 'backend', 'state'))
    for path in (source, mount, backend, state): path.mkdir(mode=0o700)
    bucket, prefix = 'fixture', 'native-finder'
    (backend/bucket).mkdir()
    payload = source/TARGET
    with payload.open('xb') as handle:
        for _ in range(64): handle.write(os.urandom(MiB))
    expected, size = digest(payload), payload.stat().st_size
    binary = root/'streaming-nfs'
    shutil.copy2(engine_binary, binary); binary.chmod(0o700)
    binary_hash = digest(binary)
    ports = set()
    while len(ports) < 3: ports.add(local.port())
    nfs, control, s3 = ports
    token, secret = os.urandom(32).hex(), os.urandom(32).hex()
    env = {key: os.environ[key] for key in ('PATH', 'HOME', 'TMPDIR', 'LANG') if key in os.environ}
    server_env = dict(env, RCLONE_AUTH_KEY='"fixture,'+secret+'"')
    engine_env = dict(env, STREAMING_CONTROL_TOKEN=token, STREAMING_S3_ACCESS_KEY='fixture', STREAMING_S3_SECRET_KEY=secret)
    engine_log = (root/'engine.log').open('wb'); server_log = (root/'s3.log').open('wb')
    server = subprocess.Popen([str(ROOT/'build/backend/rclone'), 'serve', 's3', str(backend), '--addr', f'127.0.0.1:{s3}', '--config', '/dev/null'], env=server_env, stdout=server_log, stderr=server_log)
    engine = None
    safe, success, failure = False, False, None
    measurements = {'targetSizeBytes': size, 'peakClientStateAllocatedBytes': 0, 'peakEngineRSSBytes': 0,
                    'observationIntervalSeconds': 0.02, 'preallocatedLogicalSizeIsNotAcceptedProgress': True}
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    remote_prefix = backend/bucket/prefix
    ack = root/'ack-finder-done'
    ready_at = None

    def request(route, method='GET', query=None):
        url = f'http://127.0.0.1:{control}/{route}'
        if query: url += '?' + urllib.parse.urlencode(query)
        req = urllib.request.Request(url, data=b'' if method == 'POST' else None, method=method, headers={'Authorization': 'Bearer '+token})
        with opener.open(req, timeout=40 if method == 'POST' else 3) as response:
            data = response.read(65537)
            assert len(data) <= 65536
            return json.loads(data)

    def sample():
        measurements['peakClientStateAllocatedBytes'] = max(measurements['peakClientStateAllocatedBytes'], allocated_tree(state))
        try:
            data = json.loads((state/'manifest.json').read_bytes())
        except (FileNotFoundError, json.JSONDecodeError): return 0
        node = data['Files'].get(TARGET)
        if node is None: return 0
        extents = node.get('Extents') or []
        accepted = coverage(extents, size)
        measurements['latestTargetAcceptedCoverageBytes'] = accepted
        if 'firstCommittedPayloadSecondsAfterReady' not in measurements:
            for extent in extents:
                key = extent['Key']
                parts = key.split('/')
                assert len(parts) == 2 and parts[0] == 'chunks' and len(parts[1]) == 64 and all(c in '0123456789abcdef' for c in parts[1])
                path = remote_prefix/parts[0]/parts[1]
                if path.exists() and path.stat().st_size == extent['Length']:
                    assert digest(path) == parts[1]
                    measurements['firstCommittedPayloadSecondsAfterReady'] = time.monotonic() - ready_at
                    measurements['targetAcceptedCoverageAtFirstPayloadBytes'] = accepted
                    measurements['payloadObservedBeforeCompleteTargetCoverage'] = accepted < size
                    measurements['firstPayloadMatchedExactTargetExtent'] = True
                    print(json.dumps({'event': 'first-committed-target-payload',
                                      'acceptedCoverageBytes': accepted, 'targetSizeBytes': size,
                                      'beforeCompleteTargetCoverage': accepted < size}), flush=True)
                    break
        if accepted == size and 'completeTargetCoverageSecondsAfterReady' not in measurements:
            measurements['completeTargetCoverageSecondsAfterReady'] = time.monotonic() - ready_at
        return accepted

    try:
        local.until(lambda: __import__('socket').create_connection(('127.0.0.1', s3), timeout=.2).close() is None, seconds=10)
        engine = subprocess.Popen([str(binary), '--state', str(state), '--addr', f'127.0.0.1:{nfs}', '--control', f'127.0.0.1:{control}', '--store', 's3', '--endpoint', f'http://127.0.0.1:{s3}', '--bucket', bucket, '--prefix', prefix], env=engine_env, stdout=engine_log, stderr=engine_log)
        fd = os.open(root/'fixture-control.json', os.O_CREAT|os.O_EXCL|os.O_WRONLY, 0o600)
        with os.fdopen(fd, 'w') as handle: json.dump({'enginePID': engine.pid, 's3PID': server.pid, 'controlPort': control, 'token': token, 'nfsPort': nfs}, handle)
        local.until(lambda: request('status'), seconds=10)
        local.command(['/sbin/mount_nfs', '-o', f'port={nfs},mountport={nfs},tcp,vers=3,nolocks,mutejukebox,nodev,nosuid,acregmin=0,acregmax=1,rsize=1048576,wsize=1048576', '127.0.0.1:/', str(mount)])
        assert local.is_mounted(mount)
        ready_at = time.monotonic()
        print(json.dumps({'source': str(payload), 'destination': str(mount), 'ack': str(ack), 'deadlineSeconds': 180, 'sizeBytes': size}), flush=True)
        deadline = ready_at + 180
        next_rss = 0
        while time.monotonic() < deadline:
            assert engine.poll() is None and server.poll() is None, 'fixture process exited'
            accepted = sample()
            if time.monotonic() >= next_rss:
                rss = local.command(['/bin/ps', '-o', 'rss=', '-p', str(engine.pid)], timeout=2).strip()
                if rss: measurements['peakEngineRSSBytes'] = max(measurements['peakEngineRSSBytes'], int(rss)*1024)
                next_rss = time.monotonic() + .5
            if ack.exists():
                measurements['finderCompletionAcknowledgedSecondsAfterReady'] = time.monotonic() - ready_at
                assert accepted == size, 'Finder acknowledgement arrived before all target bytes were durably represented'
                break
            time.sleep(.02)
        else: raise RuntimeError('native Finder checkpoint expired')
        assert measurements.get('payloadObservedBeforeCompleteTargetCoverage') is True, 'early payload overlap was not observed'
        # Stop new producer I/O before explicit publication. NFS COMMIT is not EOF.
        local.command(['/sbin/umount', str(mount)], timeout=15)
        assert not local.is_mounted(mount)
        final = request('status')
        assert final['poisoned'] is False and final['payloadStagingBytes'] == 0
        published = request('publish', method='POST', query={'name': TARGET, 'key': 'ordinary/'+TARGET})
        assert published.get('published') is True
        result = remote_prefix/'ordinary'/TARGET
        assert result.stat().st_size == size and digest(result) == expected
        assert payload.stat().st_size == size and digest(payload) == expected
        measurements['publishedOrdinaryObjectIndependentChecksum'] = True
        measurements['sourceOriginalUnchanged'] = True
        measurements['finalClientStateAllocatedBytes'] = allocated_tree(state)
        measurements['finalManifestBytes'] = final['manifestBytes']
        assert measurements['peakClientStateAllocatedBytes'] <= 2*final['maxManifestBytes'] + 65536
        measurements['withinClientManifestBudget'] = True
        success = True
    except BaseException as error:
        failure = str(error) or type(error).__name__
        raise
    finally:
        try:
            if local.is_mounted(mount): local.command(['/sbin/umount', str(mount)], timeout=15)
            if not local.is_mounted(mount):
                if engine is not None and engine.poll() is None: engine.terminate(); engine.wait(timeout=10)
                if engine is None or engine.poll() is not None:
                    if server.poll() is None: server.terminate(); server.wait(timeout=10)
                    safe = server.poll() is not None
        except Exception: pass
        engine_log.close(); server_log.close()
        report = {'success': success, 'safeShutdown': safe, 'failure': failure, 'engineSHA256': binary_hash,
                  'measurements': measurements, 'scope': 'actual native Finder via operator; isolated loopback authenticated S3; no R2',
                  'copyDurationKnown': False, 'acknowledgementIncludesOperatorDelay': True,
                  'rssMeasurementPhase': 'copy and operator checkpoint; publication not sampled',
                  'sampledPeakIsNotHardRAMBound': True,
                  'clientAllocationExcludesRemoteS3EmulatorAndSourceOriginal': True,
                  'fixtureRetained': None if success and safe else str(root)}
        args.report.write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps(report), flush=True)
        if success and safe: shutil.rmtree(root)


if __name__ == '__main__': main()
