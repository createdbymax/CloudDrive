#!/usr/bin/env python3
"""Measure the current Finder/NFS staging timeline using generated loopback S3 data.

No owner state, keys or provider. A slow subprocess writes through native NFS;
a streaming HTTP proxy counts only target-object PUT body bytes, excluding
headers and control/metadata traffic. No whole-body proxy buffering.
"""
import argparse, base64, hashlib, http.client, http.server, importlib.util, json
import os, pathlib, shutil, subprocess, sys, tempfile, threading, time
import urllib.parse, urllib.request
ROOT=pathlib.Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('local',ROOT/'scripts/qualify-local.py')
local=importlib.util.module_from_spec(spec);spec.loader.exec_module(local)
MiB=1024*1024

class PayloadTracker:
    """Count object bytes; optionally strip AWS signed-chunk framing."""
    def __init__(self, encoded, observe):
        self.encoded=encoded;self.observe=observe;self.buffer=b'';self.remaining=None;self.finished=False
    def feed(self,data):
        if not self.encoded:self.observe(len(data));return
        self.buffer+=data
        while self.buffer and not self.finished:
            if self.remaining is None:
                end=self.buffer.find(b'\r\n')
                if end<0:return
                self.remaining=int(self.buffer[:end].split(b';')[0],16);self.buffer=self.buffer[end+2:]
                if self.remaining==0:self.finished=True;return
            n=min(self.remaining,len(self.buffer))
            self.observe(n);self.remaining-=n;self.buffer=self.buffer[n:]
            if self.remaining==0:
                if len(self.buffer)<2:return
                assert self.buffer[:2]==b'\r\n';self.buffer=self.buffer[2:];self.remaining=None

class Observation:
    def __init__(self):self.lock=threading.Lock();self.target=None;self.started=0;self.first=None;self.total=0;self.requests=0;self.commit=None
    def begin(self,target):
        with self.lock:self.target=target;self.started=time.monotonic();self.first=None;self.total=0;self.requests=0;self.commit=None
    def accepts(self,path):
        with self.lock:return urllib.parse.unquote(urllib.parse.urlsplit(path).path)=='/bucket/'+str(self.target)
    def request(self):
        with self.lock:self.requests+=1
    def committed(self):
        with self.lock:self.commit=time.monotonic()
    def bytes(self,n):
        if n<=0:return
        with self.lock:
            if self.first is None:self.first=time.monotonic()
            self.total+=n
    def snapshot(self):
        with self.lock:return {'firstPayloadAt':self.first,'payloadBytes':self.total,'payloadRequests':self.requests,'commitAcknowledgedAt':self.commit}

class Proxy(http.server.BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*args):pass
    def do_GET(self):self.forward()
    def do_HEAD(self):self.forward()
    def do_PUT(self):self.forward()
    def do_POST(self):self.forward()
    def do_DELETE(self):self.forward()
    def forward(self):
        connection=http.client.HTTPConnection('127.0.0.1',self.server.destination,timeout=30)
        try:
            connection.putrequest(self.command,self.path,skip_host=True,skip_accept_encoding=True)
            for key,value in self.headers.items():
                if key.lower() not in ('connection','expect'):connection.putheader(key,value)
            connection.putheader('Connection','close');connection.endheaders()
            tracker=None
            if self.command=='PUT' and self.server.observation.accepts(self.path):
                self.server.observation.request()
                tracker=PayloadTracker('aws-chunked' in self.headers.get('Content-Encoding',''),self.server.observation.bytes)
            def send(data,payload=True):
                connection.send(data)
                if payload and tracker:tracker.feed(data)
            if self.headers.get('Transfer-Encoding','').lower()=='chunked':
                while True:
                    line=self.rfile.readline(8192);send(line,False)
                    size=int(line.split(b';')[0],16)
                    if size==0:
                        while True:
                            line=self.rfile.readline(8192);send(line,False)
                            if line==b'\r\n':break
                        break
                    remaining=size
                    while remaining:
                        data=self.rfile.read(min(65536,remaining));assert data;send(data);remaining-=len(data)
                    ending=self.rfile.read(2);assert ending==b'\r\n';send(ending,False)
            else:
                remaining=int(self.headers.get('Content-Length','0'))
                while remaining:
                    data=self.rfile.read(min(65536,remaining));assert data;send(data);remaining-=len(data)
            response=connection.getresponse();self.send_response(response.status)
            for key,value in response.getheaders():
                if key.lower() not in ('connection','transfer-encoding','content-length'):self.send_header(key,value)
            # Responses are control XML/headers, never object data in this write-only fixture.
            body=response.read()
            query=urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            final_put=self.command=='PUT' and 'partNumber' not in query
            multipart_complete=self.command=='POST' and 'uploadId' in query
            if 200<=response.status<300 and b'<Error>' not in body and self.server.observation.accepts(self.path) and (final_put or multipart_complete):self.server.observation.committed()
            response_length=response.getheader('Content-Length','0') if self.command=='HEAD' else str(len(body))
            self.send_header('Content-Length',response_length);self.send_header('Connection','close');self.end_headers()
            if self.command!='HEAD':self.wfile.write(body)
            self.close_connection=True
        except Exception:
            self.close_connection=True
            try:self.send_error(502)
            except OSError:pass
        finally:connection.close()

def digest(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for b in iter(lambda:f.read(MiB),b''):h.update(b)
    return h.hexdigest()

def allocated(path):
    try:return path.stat().st_blocks*512
    except FileNotFoundError:return 0

def rss(pid):
    try:return int(subprocess.check_output(['/bin/ps','-o','rss=','-p',str(pid)],timeout=2).strip())*1024
    except (ValueError,subprocess.SubprocessError):return None

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rclone',type=pathlib.Path,default=ROOT/'build/backend/rclone')
    parser.add_argument('--sizes-mib',type=int,nargs='+',default=[256,1024])
    parser.add_argument('--producer-mib-per-second',type=float,default=16)
    parser.add_argument('--upload-mib-per-second',type=float,default=32)
    parser.add_argument('--report',type=pathlib.Path,default=pathlib.Path('/tmp/clouddrive-copy-timeline-report.json'))
    args=parser.parse_args();binary=args.rclone.resolve(strict=True)
    assert all(n>0 for n in args.sizes_mib) and args.producer_mib_per_second>0 and args.upload_mib_per_second>0
    root=pathlib.Path(tempfile.mkdtemp(prefix='clouddrive-copy-timeline-')).resolve();root.chmod(0o700)
    backend,mount,cache=root/'backend',root/'mount',root/'cache';backend.mkdir();mount.mkdir();source=backend/'bucket';source.mkdir()
    seed=os.urandom(MiB);(root/'seed.bin').write_bytes(seed)
    nfs,rc,s3=[local.port() for _ in range(3)];assert len({nfs,rc,s3})==3
    observation=Observation();proxy=http.server.ThreadingHTTPServer(('127.0.0.1',0),Proxy);proxy.daemon_threads=True
    proxy.destination=s3;proxy.observation=observation
    threading.Thread(target=proxy.serve_forever,daemon=True).start()
    env={k:os.environ[k] for k in ('PATH','HOME','TMPDIR','LANG') if k in os.environ};secret=os.urandom(32).hex();token=os.urandom(32).hex()
    serverenv=env.copy();serverenv['RCLONE_AUTH_KEY']='"fixture,'+secret+'"'
    serverlog=(root/'server.log').open('wb');log=(root/'worker.log').open('wb')
    server=subprocess.Popen([str(binary),'serve','s3',str(backend),'--addr',f'127.0.0.1:{s3}','--config','/dev/null'],env=serverenv,stdout=serverlog,stderr=serverlog)
    env.update(RCLONE_CONFIG_FIXTURE_TYPE='s3',RCLONE_CONFIG_FIXTURE_PROVIDER='Other',RCLONE_CONFIG_FIXTURE_ACCESS_KEY_ID='fixture',RCLONE_CONFIG_FIXTURE_SECRET_ACCESS_KEY=secret,RCLONE_CONFIG_FIXTURE_ENDPOINT=f'http://127.0.0.1:{proxy.server_port}',RCLONE_CONFIG_FIXTURE_FORCE_PATH_STYLE='true',RCLONE_CONFIG_FIXTURE_NO_CHECK_BUCKET='true',RCLONE_RC_USER='fixture',RCLONE_RC_PASS=token)
    worker=subprocess.Popen([str(binary),'serve','nfs','fixture:bucket','--addr',f'127.0.0.1:{nfs}','--config','/dev/null','--cache-dir',str(cache),'--vfs-cache-mode','full','--vfs-cache-max-age','1s','--vfs-cache-poll-interval','1s','--vfs-write-back','2s','--bwlimit',f'{int(args.upload_mib_per_second*MiB)}B:off','--rc','--rc-addr',f'127.0.0.1:{rc}'],env=env,stdout=log,stderr=log)
    record=root/'fixture-control.json';record.write_text(json.dumps({'pid':worker.pid,'serverPID':server.pid,'nfsPort':nfs,'controlPort':rc,'token':token}));record.chmod(0o600)
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}));cases=[];success=False;producer=None
    def control():
        req=urllib.request.Request(f'http://127.0.0.1:{rc}/vfs/stats',data=b'{}',headers={'Authorization':'Basic '+base64.b64encode(('fixture:'+token).encode()).decode()})
        with opener.open(req,timeout=2) as r:return json.load(r)
    def idle():
        d=control()['diskCache'];return all(type(d[k])is int and d[k]==0 for k in ('uploadsQueued','uploadsInProgress','erroredFiles')) and d['outOfSpace'] is False
    try:
        local.until(control);cache_root=pathlib.Path(control()['diskCache']['path']);assert cache in cache_root.parents
        local.command(['/sbin/mount_nfs','-o',f'port={nfs},mountport={nfs},tcp,vers=3,nolocks,mutejukebox,nodev,nosuid','127.0.0.1:/',str(mount)])
        for size_mib in args.sizes_mib:
            size=size_mib*MiB
            if shutil.disk_usage(root).free<4*size+2*1024*MiB:
                cases.append({'sizeBytes':size,'skipped':'insufficient disposable fixture space plus reserve'});continue
            name=f'timeline-{size_mib}MiB.bin';target=mount/name;cached=cache_root/name;committed=source/name
            h=hashlib.sha256()
            for _ in range(size_mib):h.update(seed)
            expected=h.hexdigest();eventsfile=root/(name+'.events.json');observation.begin(name);started=time.monotonic();started_wall=time.time()
            script='''import json,os,pathlib,sys,time
path,seedpath,eventspath,count,rate=sys.argv[1:];count=int(count);rate=float(rate);block=pathlib.Path(seedpath).read_bytes();events={};start=time.monotonic()
with open(path,'xb',buffering=0) as f:
 for i in range(count):
  n=f.write(block);assert n==len(block)
  if i==0:events['firstWriteReturnedAt']=time.time();pathlib.Path(eventspath).write_text(json.dumps(events))
  if i%8==7:os.fsync(f.fileno())
  time.sleep(max(0,start+(i+1)/rate-time.monotonic()))
 f.flush();os.fsync(f.fileno());events['finalFsyncReturnedAt']=time.time()
events['producerClosedAt']=time.time();pathlib.Path(eventspath).write_text(json.dumps(events))
'''
            producer=subprocess.Popen([sys.executable,'-c',script,str(target),str(root/'seed.bin'),str(eventsfile),str(size_mib),str(args.producer_mib_per_second)],stdout=subprocess.DEVNULL,stderr=(root/(name+'.producer.log')).open('wb'))
            peak=0;peakwhileopen=0;worker_rss=0;server_rss=0;commit_at=None;evict_at=None;last_rss=0;samples=[]
            deadline=time.monotonic()+size_mib/args.producer_mib_per_second+size_mib/args.upload_mib_per_second+70
            while time.monotonic()<deadline:
                now=time.monotonic();allocation=allocated(cached);peak=max(peak,allocation)
                if producer.poll() is None:peakwhileopen=max(peakwhileopen,allocation)
                if now-last_rss>.5:
                    worker_rss=max(worker_rss,rss(worker.pid) or 0);server_rss=max(server_rss,rss(server.pid) or 0);last_rss=now
                try:
                    if commit_at is None and committed.stat().st_size==size:commit_at=now
                except FileNotFoundError:pass
                if commit_at and not cached.exists():evict_at=now;break
                if not samples or now-samples[-1]['atSeconds']-started>=1:
                    snap=observation.snapshot();samples.append({'atSeconds':now-started,'cacheAllocatedBytes':allocation,'outboundPayloadBytes':snap['payloadBytes'],'producerRunning':producer.poll() is None})
                time.sleep(.1)
            assert producer.poll()==0,'producer failed or deadline expired'
            assert commit_at and evict_at,'commit/eviction deadline exceeded'
            producer_events={k:v-started_wall+started for k,v in json.loads(eventsfile.read_text()).items()};payload_events=observation.snapshot()
            assert payload_events['firstPayloadAt'] is not None and payload_events['payloadBytes']==size,payload_events
            assert payload_events['commitAcknowledgedAt'] is not None
            assert digest(committed)==expected,'independent backend checksum mismatch'
            checksum_at=time.monotonic();local.until(idle,seconds=15)
            events={**producer_events,'firstOutboundObjectPayloadAt':payload_events['firstPayloadAt'],'remoteCommitAcknowledgedAt':payload_events['commitAcknowledgedAt'],'remoteFullSizeFirstObservedAt':commit_at,'cacheEvictionObservedAt':evict_at,'independentChecksumCompletedAt':checksum_at}
            relative={k:round(v-started,4) for k,v in events.items()}
            row={'sizeBytes':size,'sha256':expected,'eventsSecondsFromProducerLaunch':relative,'outboundPayloadBytes':payload_events['payloadBytes'],'objectPayloadRequests':payload_events['payloadRequests'],'cachePeakAllocatedBytes':peak,'cachePeakWhileProducerOpenBytes':peakwhileopen,'workerPeakRSSBytes':worker_rss,'fixtureS3ServerPeakRSSBytes':server_rss,'payloadBeganBeforeProducerClose':payload_events['firstPayloadAt']<producer_events['producerClosedAt'],'cacheAllocationAtEvictionBytes':allocated(cached),'samples':samples}
            assert row['cachePeakAllocatedBytes']>=size,'did not observe full staging allocation'
            assert not row['payloadBeganBeforeProducerClose'],'baseline unexpectedly streams; investigate'
            cases.append(row);print(json.dumps({k:v for k,v in row.items() if k!='samples'}),flush=True)
        assert len([r for r in cases if 'skipped' not in r])>0
        local.command(['/sbin/umount',str(mount)]);local.until(idle);worker.terminate();worker.wait(timeout=10);server.terminate();server.wait(timeout=10);success=True
    finally:
        safe=False
        try:
            if producer and producer.poll() is None:
                producer.terminate();producer.wait(timeout=5)
            if local.is_mounted(mount):local.command(['/sbin/umount',str(mount)])
            if not local.is_mounted(mount):
                if worker.poll() is None:local.until(idle,seconds=45);worker.terminate();worker.wait(timeout=10)
                if server.poll() is None:server.terminate();server.wait(timeout=10)
                safe=worker.poll() is not None and server.poll() is not None
        except Exception:pass
        proxy.shutdown();proxy.server_close();log.close();serverlog.close()
        report={'success':success,'safeShutdown':safe,'backendVersion':local.command([str(binary),'version']).splitlines()[0],'binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest(),'producerMiBPerSecond':args.producer_mib_per_second,'uploadLimitMiBPerSecond':args.upload_mib_per_second,'samplingIntervalSeconds':.1,'cases':cases,'fixtureRetained':None if success and safe else str(root)}
        args.report.write_text(json.dumps(report,indent=2)+'\n');print('Report: '+str(args.report),flush=True)
        if success and safe:shutil.rmtree(root)
        else:print('Retained fixture; do not remove while mounted: '+str(root),file=sys.stderr)
if __name__=='__main__':main()
