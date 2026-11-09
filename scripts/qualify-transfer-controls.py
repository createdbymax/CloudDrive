#!/usr/bin/env python3
"""Isolated native NFS transfer-control qualification; no owner state or provider.

Uses generated files and authenticated loopback RC. Retains failed fixtures.
Normal unmount and queue drain are required before worker exit and cleanup.
"""
import argparse, base64, hashlib, importlib.util, json, os, pathlib, shutil
import subprocess, sys, tempfile, time, urllib.request, urllib.error
ROOT=pathlib.Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('local',ROOT/'scripts/qualify-local.py')
local=importlib.util.module_from_spec(spec);spec.loader.exec_module(local)
MiB=1024*1024

def digest(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for b in iter(lambda:f.read(MiB),b''):h.update(b)
    return h.hexdigest()

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rclone',type=pathlib.Path,default=ROOT/'build/backend/rclone')
    parser.add_argument('--report',type=pathlib.Path,default=pathlib.Path('/tmp/clouddrive-transfer-controls-report.json'))
    args=parser.parse_args();binary=args.rclone.resolve(strict=True)
    root=pathlib.Path(tempfile.mkdtemp(prefix='clouddrive-transfer-controls-')).resolve();root.chmod(0o700)
    backend=root/'backend';backend.mkdir()
    source,mount,cache=backend/'bucket',root/'mount',root/'cache';source.mkdir();mount.mkdir()
    payload=root/'payload.bin';payload.write_bytes(os.urandom(32*MiB));expected=digest(payload)
    cold=source/'cold.bin';cold.write_bytes(os.urandom(16*MiB));cold_expected=digest(cold)
    nfs,rc=local.port(),local.port()
    while nfs==rc:rc=local.port()
    token=os.urandom(32).hex();env={k:os.environ[k] for k in ('PATH','HOME','TMPDIR','LANG') if k in os.environ}
    s3port=local.port();s3secret=os.urandom(32).hex()
    server_env=env.copy();server_env['RCLONE_AUTH_KEY']='"fixture,'+s3secret+'"'
    server_log=(root/'s3.log').open('wb')
    server=subprocess.Popen([str(binary),'serve','s3',str(backend),'--addr',f'127.0.0.1:{s3port}','--config','/dev/null'],env=server_env,stdout=server_log,stderr=server_log)
    env.update(RCLONE_CONFIG_FIXTURE_TYPE='s3',RCLONE_CONFIG_FIXTURE_PROVIDER='Other',RCLONE_CONFIG_FIXTURE_ACCESS_KEY_ID='fixture',RCLONE_CONFIG_FIXTURE_SECRET_ACCESS_KEY=s3secret,RCLONE_CONFIG_FIXTURE_ENDPOINT=f'http://127.0.0.1:{s3port}',RCLONE_CONFIG_FIXTURE_FORCE_PATH_STYLE='true',RCLONE_CONFIG_FIXTURE_NO_CHECK_BUCKET='true',RCLONE_CONFIG_FIXTURE_UPLOAD_CUTOFF='64M')
    env.update(RCLONE_RC_USER='fixture',RCLONE_RC_PASS=token)
    log=(root/'worker.log').open('wb')
    worker=subprocess.Popen([str(binary),'serve','nfs','fixture:bucket','--addr',f'127.0.0.1:{nfs}','--config','/dev/null','--cache-dir',str(cache),'--vfs-cache-mode','full','--vfs-cache-max-age','1s','--vfs-cache-poll-interval','1s','--vfs-write-back','2s','--transfers','1','--low-level-retries','1','--rc','--rc-addr',f'127.0.0.1:{rc}'],env=env,stdout=log,stderr=log)
    record=root/'fixture-control.json';record.write_text(json.dumps({'pid':worker.pid,'serverPID':server.pid,'controlPort':rc,'nfsPort':nfs,'s3Port':s3port,'token':token}));record.chmod(0o600)
    (root/'fixture-ledger.json').write_text(json.dumps({'upload.bin':{'size':32*MiB,'sha256':expected},'cold.bin':{'size':16*MiB,'sha256':cold_expected}},indent=2)+'\n')
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}));passed=[];measurements={};success=False
    def control(route='vfs/stats',params=None):
        request=urllib.request.Request(f'http://127.0.0.1:{rc}/{route}',data=json.dumps(params or {}).encode(),headers={'Content-Type':'application/json','Authorization':'Basic '+base64.b64encode(f'fixture:{token}'.encode()).decode()})
        with opener.open(request,timeout=3) as r:return json.load(r)
    selected_fs=None
    def queue():return control('vfs/queue',{'fs':selected_fs}).get('queue') or []
    def item(name):return next((q for q in queue() if q['name']==name),None)
    def idle():
        d=control()['diskCache'];v=[d[k] for k in ('uploadsQueued','uploadsInProgress','erroredFiles')]
        assert all(type(x)is int and x>=0 for x in v)
        return v==[0,0,0] and d['outOfSpace'] is False
    def cap(mbps):
        # Decimal Mbps -> exact integer bytes/s; B suffix prevents KiB default.
        tx=-1 if mbps is None else int(mbps*1_000_000/8)
        setting='off' if mbps is None else f'{tx}B:off'
        response=control('core/bwlimit',{'rate':setting});readback=control('core/bwlimit')
        assert response['bytesPerSecondTx']==readback['bytesPerSecondTx']==tx
        assert response['bytesPerSecondRx']==readback['bytesPerSecondRx']==-1
        return readback
    def bytes_for(name):
        rows=control('core/stats').get('transferring') or []
        row=next((x for x in rows if x['name']==name and x.get('dstFs')==selected_fs),None)
        if row is None:return None
        measurements['transfer_destination']=row.get('dstFs')
        assert type(row['bytes'])is int and row['bytes']>=0
        return row['bytes']
    def sample(name,seconds=4):
        local.until(lambda:bytes_for(name) is not None,seconds=10)
        a=bytes_for(name);started=time.monotonic();time.sleep(seconds);b=bytes_for(name)
        assert b is not None and b>=a,'transfer ended during sample'
        return (b-a)/(time.monotonic()-started)
    def copy(name,src=payload):
        local.filesystem('import os,shutil,sys\nwith open(sys.argv[1],"rb") as s,open(sys.argv[2],"xb") as d:\n shutil.copyfileobj(s,d,1024*1024);d.flush();os.fsync(d.fileno())',src,mount/name)
    try:
        local.until(control);selected_fs=control()['fs'];assert selected_fs.startswith('fixture') and selected_fs.endswith(':bucket')
        cache_root=pathlib.Path(control()['diskCache']['path']);assert cache in cache_root.parents
        low=cap(8);passed.append('8 Mbps converts exactly to 1000000 bytes/s transmit, unlimited receive')
        local.command(['/sbin/mount_nfs','-o',f'port={nfs},mountport={nfs},tcp,vers=3,nolocks,mutejukebox,nodev,nosuid','127.0.0.1:/',str(mount)])
        copy('upload.bin');local.until(lambda:item('upload.bin') and item('upload.bin')['uploading'])
        time.sleep(1);slow=sample('upload.bin');measurements['8Mbps_observed_bytes_per_second']=round(slow)
        assert .65*1_000_000<slow<1.35*1_000_000,slow
        high=cap(16);time.sleep(1);fast=sample('upload.bin');measurements['16Mbps_observed_bytes_per_second']=round(fast)
        assert .65*2_000_000<fast<1.35*2_000_000,fast
        passed.append('active upload cap changes from 8 to16 Mbps and measured windows follow both within35 percent')
        # Cold file never read through mount/cache before this operation.
        cap(1);assert not (cache_root/'cold.bin').exists()
        started=time.monotonic();output=local.command([sys.executable,'-c','import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())',str(mount/'cold.bin')],timeout=15)
        elapsed=time.monotonic()-started;assert output.strip()==cold_expected
        measurements['cold_16MiB_read_seconds_with_1Mbps_upload_cap']=round(elapsed,3)
        assert elapsed<8, 'cold read unexpectedly approaches upload-only cap'
        assert control('core/bwlimit')['bytesPerSecondRx']==-1
        passed.append('cold16MiB NFS read checksum passes while receive remains unlimited under1Mbps transmit cap')
        active=item('upload.bin');assert active and active['uploading']
        before=bytes_for('upload.bin');control('vfs/queue-set-expiry',{'fs':selected_fs,'id':active['id'],'expiry':3600})
        cap(16);time.sleep(2);after=bytes_for('upload.bin')
        assert after is not None and after>before
        passed.append('expiry adjustment does not pause an already-active upload')
        try:control('core/bwlimit',{'rate':'invalid-fixture-rate'})
        except urllib.error.HTTPError:pass
        else:raise AssertionError('invalid bandwidth request succeeded')
        assert control('core/bwlimit')['bytesPerSecondTx']==2_000_000
        passed.append('invalid cap request returns error and previous applied setting remains')
        cap(None);local.until(idle,seconds=30);assert digest(source/'upload.bin')==expected
        passed.append('independent32MiB upload checksum after queue drain')
        source.chmod(0o500)
        retry_payload=root/'retry.bin';retry_payload.write_bytes(os.urandom(MiB));retry_digest=digest(retry_payload)
        try:
            copy('retry.bin',retry_payload)
            local.until(lambda:item('retry.bin') and item('retry.bin')['tries']>=1 and not item('retry.bin')['uploading'],seconds=20)
            q=item('retry.bin');assert q['name']=='retry.bin' and q['size']==MiB
            assert digest(cache_root/'retry.bin')==retry_digest and not (source/'retry.bin').exists()
            # Enlarge retry wait then check exact identity immediately before retry-now.
            control('vfs/queue-set-expiry',{'fs':selected_fs,'id':q['id'],'expiry':60})
            delayed=item('retry.bin');assert delayed['id']==q['id'] and delayed['expiry']>50
            try:control('vfs/queue-set-expiry',{'fs':selected_fs,'id':q['id']+1_000_000,'expiry':-1_000_000_000})
            except urllib.error.HTTPError:pass
            else:raise AssertionError('missing queue ID accepted')
        finally:source.chmod(0o700)
        current=item('retry.bin');assert current['id']==q['id'] and current['name']==q['name'] and current['size']==q['size'] and not current['uploading']
        started=time.monotonic();control('vfs/queue-set-expiry',{'fs':selected_fs,'id':current['id'],'expiry':-1_000_000_000})
        local.until(idle,seconds=10);measurements['retry_now_to_drain_seconds']=round(time.monotonic()-started,3)
        assert digest(source/'retry.bin')==retry_digest
        passed.append('failed upload retains bytes; exact queued identity retry-now bypasses60s delay and checksum passes')
        passed.append('unknown queue ID rejected without changing queued fixture')
        local.command(['/sbin/umount',str(mount)]);local.until(idle);worker.terminate();worker.wait(timeout=10)
        passed.append('safe normal unmount, queue drain and confirmed worker exit');success=True
    finally:
        source.chmod(0o700);safe=False
        try:
            if local.is_mounted(mount):local.command(['/sbin/umount',str(mount)])
            if not local.is_mounted(mount):
                if worker.poll() is None:
                    cap(None)
                    for q in queue():
                        if not q['uploading']:control('vfs/queue-set-expiry',{'fs':selected_fs,'id':q['id'],'expiry':-1_000_000_000})
                    local.until(idle,seconds=15);worker.terminate();worker.wait(timeout=10)
                safe=worker.poll() is not None
        except Exception:pass
        if safe and server.poll() is None:server.terminate();server.wait(timeout=10)
        safe=safe and server.poll() is not None
        log.close();server_log.close()
        report={'success':success,'safeShutdown':safe,'passed':passed,'measurements':measurements,'binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest(),'backendVersion':local.command([str(binary),'version']).splitlines()[0],'fixtureRetained':None if success and safe else str(root)}
        args.report.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
        if success and safe:shutil.rmtree(root)
        else:print('Retained fixture; never recursively remove a mounted fixture: '+str(root),file=sys.stderr)
if __name__=='__main__':main()
