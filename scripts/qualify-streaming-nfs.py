#!/usr/bin/env python3
"""Isolated S1 spike: native NFS -> durable HTTP S3 chunks -> explicit publication.

Generated data only. Never reads owner state, R2 keys or app settings. This does
not supply Finder EOF detection, a production journal, encryption or a release.
"""
import argparse,base64,hashlib,http.client,http.server,importlib.util,json,os,pathlib
import secrets,shutil,socket,stat,struct,subprocess,sys,tempfile,threading,time,urllib.parse,urllib.request
ROOT=pathlib.Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('local',ROOT/'scripts/qualify-local.py');local=importlib.util.module_from_spec(spec);spec.loader.exec_module(local)
MiB=1024*1024

class Network:
    def __init__(self,rate):
        self.lock=threading.Lock();self.rate=rate;self.offline=False;self.first=None;self.payloadByKey={};self.commitByKey={}
        self.counts={'chunkPutBytes':0,'chunkPutRequests':0,'chunkCommitResponses':0,'chunkGetBytes':0,'chunkGetRequests':0,'ordinaryPutBytes':0,'ordinaryPutRequests':0,'multipartControlRequests':0}
    def add(self,key,n=1):
        with self.lock:
            self.counts[key]+=n
            if key=='chunkPutBytes' and n and self.first is None:self.first=time.time()
    def snapshot(self):
        with self.lock:return {**self.counts,'firstChunkPayloadAtEpoch':self.first}
    def begin_case(self):
        with self.lock:self.payloadByKey={};self.commitByKey={}
    def payload(self,path,n):
        self.add('chunkPutBytes',n)
        with self.lock:self.payloadByKey.setdefault(path,time.time())
    def committed(self,path):
        self.add('chunkCommitResponses')
        with self.lock:self.commitByKey[path]=time.time()
    def user_events(self,manifest,names):
        keys=['/fixture/streaming-experiment/'+e['Key'] for name in names for e in (manifest.get('Files',{}).get(name,{}).get('Extents') or [])]
        with self.lock:
            payload=[self.payloadByKey[k] for k in keys if k in self.payloadByKey]
            commits=[self.commitByKey[k] for k in keys if k in self.commitByKey]
        return (min(payload) if payload else None,min(commits) if commits else None)

class Proxy(http.server.BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*args):pass
    def do_GET(self):self.forward()
    def do_HEAD(self):self.forward()
    def do_PUT(self):self.forward()
    def do_POST(self):self.forward()
    def do_DELETE(self):self.forward()
    def forward(self):
        network=self.server.network
        if network.offline:self.send_error(503);self.close_connection=True;return
        path=urllib.parse.urlsplit(self.path).path
        chunk='/streaming-experiment/chunks/' in path;ordinary='/streaming-experiment/ordinary/' in path
        if chunk and self.command=='PUT':network.add('chunkPutRequests')
        if chunk and self.command=='GET':network.add('chunkGetRequests')
        if ordinary and self.command=='PUT':network.add('ordinaryPutRequests')
        if ordinary and self.command in ('POST','DELETE'):network.add('multipartControlRequests')
        conn=http.client.HTTPConnection('127.0.0.1',self.server.destination,timeout=35)
        try:
            conn.putrequest(self.command,self.path,skip_host=True,skip_accept_encoding=True)
            for k,v in self.headers.items():
                if k.lower() not in ('connection','expect'):conn.putheader(k,v)
            conn.putheader('Connection','close');conn.endheaders()
            assert 'chunked' not in self.headers.get('Transfer-Encoding','').lower(),'spike client must declare bounded body'
            remaining=int(self.headers.get('Content-Length','0'));started=time.monotonic();sent=0
            while remaining:
                data=self.rfile.read(min(65536,remaining));assert data
                conn.send(data);remaining-=len(data);sent+=len(data)
                if chunk and self.command=='PUT':
                    network.payload(path,len(data))
                    if network.rate:time.sleep(max(0,started+sent/network.rate-time.monotonic()))
                if ordinary and self.command=='PUT':network.add('ordinaryPutBytes',len(data))
            response=conn.getresponse();body=response.read(2*MiB+1)
            assert len(body)<=2*MiB,'unexpected fixture response exceeds bounded proxy allocation'
            if chunk and self.command=='PUT' and 200<=response.status<300:network.committed(path)
            if chunk and self.command=='GET' and response.status==200:network.add('chunkGetBytes',len(body))
            self.send_response(response.status)
            for k,v in response.getheaders():
                if k.lower() not in ('connection','transfer-encoding','content-length'):self.send_header(k,v)
            self.send_header('Content-Length',response.getheader('Content-Length','0') if self.command=='HEAD' else str(len(body)))
            self.send_header('Connection','close');self.end_headers()
            if self.command!='HEAD':self.wfile.write(body)
            self.close_connection=True
        except Exception:
            self.close_connection=True
            try:self.send_error(502)
            except OSError:pass
        finally:conn.close()

def digest(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for b in iter(lambda:f.read(MiB),b''):h.update(b)
    return h.hexdigest()

def allocation(root):
    # Only the experiment state, never the mounted tree or store payload.
    total=0
    for p in root.iterdir():
        try:s=p.lstat()
        except FileNotFoundError:continue # Atomic manifest.next -> manifest.json rename.
        assert stat.S_ISREG(s.st_mode);total+=s.st_blocks*512
    return total

def rss(pid):
    try:return int(subprocess.check_output(['/bin/ps','-o','rss=','-p',str(pid)],timeout=2).strip())*1024
    except (ValueError,subprocess.SubprocessError):return 0

def expected_digest(seed,count):
    h=hashlib.sha256()
    for i in range(count):h.update(hashlib.shake_256(seed+i.to_bytes(8,'big')).digest(MiB))
    return h.hexdigest()

def delta(before,after):return {k:after[k]-v for k,v in before.items() if type(v)is int}

def opaque(value):return struct.pack('!I',len(value))+value+b'\0'*((-len(value))%4)

class WireNFS:
    """Bounded direct RPC avoids kernel retry/replay ambiguity during crash injection."""
    def __init__(self,port):self.port=port
    def call(self,program,procedure,args):
        xid=secrets.randbits(32);body=struct.pack('!10I',xid,0,2,program,3,procedure,0,0,0,0)+args
        with socket.create_connection(('127.0.0.1',self.port),timeout=3) as conn:
            deadline=time.monotonic()+3
            conn.settimeout(3);conn.sendall(struct.pack('!I',0x80000000|len(body))+body)
            def take(n):
                data=b''
                while len(data)<n:
                    remaining=deadline-time.monotonic()
                    if remaining<=0:raise TimeoutError('absolute RPC deadline')
                    conn.settimeout(remaining)
                    try:block=conn.recv(n-len(data))
                    except ConnectionResetError:raise EOFError('fixture exited before RPC reply')
                    if not block:raise EOFError('fixture exited before RPC reply')
                    data+=block
                return data
            response=b''
            for _ in range(32):
                fragment=struct.unpack('!I',take(4))[0];length=fragment&0x7fffffff
                assert len(response)+length<=2*MiB,'RPC reply exceeds qualification bound'
                response+=take(length)
                if fragment&0x80000000:break
            else:raise AssertionError('too many RPC fragments')
            rx,kind,reply,flavor,length=struct.unpack_from('!5I',response)
            assert rx==xid and kind==1 and reply==0 and length<=4096
            offset=20+length+((-length)%4);assert struct.unpack_from('!I',response,offset)[0]==0
            return response[offset+4:]
    def get_opaque(self,data,offset):
        length=struct.unpack_from('!I',data,offset)[0];offset+=4
        assert length<=MiB and offset+length<=len(data)
        return data[offset:offset+length],offset+length+((-length)%4)
    def handle(self,name):
        mounted=self.call(100005,1,opaque(b'/'));assert struct.unpack_from('!I',mounted)[0]==0
        root,_=self.get_opaque(mounted,4);lookup=self.call(100003,3,opaque(root)+opaque(name.encode()));assert struct.unpack_from('!I',lookup)[0]==0
        handle,_=self.get_opaque(lookup,4);return handle
    def size(self,handle):
        attrs=self.call(100003,1,opaque(handle));assert struct.unpack_from('!I',attrs)[0]==0
        return struct.unpack_from('!Q',attrs,24)[0]
    def read_digest(self,name):
        handle=self.handle(name);size=self.size(handle);h=hashlib.sha256();offset=0
        while offset<size:
            response=self.call(100003,6,opaque(handle)+struct.pack('!QI',offset,min(MiB,size-offset)))
            assert struct.unpack_from('!I',response)[0]==0
            attributes=struct.unpack_from('!I',response,4)[0];cursor=8+(84 if attributes else 0)
            count,eof=struct.unpack_from('!II',response,cursor);data,_=self.get_opaque(response,cursor+8)
            assert len(data)==count and count>0;h.update(data);offset+=count
        return h.hexdigest()

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--engine',type=pathlib.Path,default=ROOT/'experiments/streaming-nfs/bin/streaming-nfs')
    parser.add_argument('--rclone',type=pathlib.Path,default=ROOT/'build/backend/rclone')
    parser.add_argument('--sizes-mib',type=int,nargs='+',default=[256,1024])
    parser.add_argument('--concurrent-mib',type=int,default=256,help='Two files of this size, zero to skip')
    parser.add_argument('--producer-mib-per-second',type=float,default=32)
    parser.add_argument('--network-mib-per-second',type=float,default=16)
    parser.add_argument('--faults-only',action='store_true',help='Small separate outage/crash fixture using bounded soft NFS; does not qualify hard-mount failure behavior')
    parser.add_argument('--report',type=pathlib.Path,default=pathlib.Path('/tmp/clouddrive-streaming-nfs-report.json'))
    args=parser.parse_args();assert all(n>0 for n in args.sizes_mib) and args.concurrent_mib>=0
    if args.faults_only:args.sizes_mib=[];args.concurrent_mib=0
    root=pathlib.Path(tempfile.mkdtemp(prefix='clouddrive-streaming-nfs-')).resolve();root.chmod(0o700)
    state,backend,mount=root/'state',root/'backend',root/'mount';state.mkdir();backend.mkdir();mount.mkdir();(backend/'fixture').mkdir()
    binary=root/'streaming-nfs';shutil.copy2(args.engine.resolve(strict=True),binary);binary.chmod(0o700)
    seed=os.urandom(32);(root/'seed.bin').write_bytes(seed)
    nfs,control,s3=[local.port() for _ in range(3)];assert len({nfs,control,s3})==3
    network=Network(args.network_mib_per_second*MiB);proxy=http.server.ThreadingHTTPServer(('127.0.0.1',0),Proxy);proxy.daemon_threads=True;proxy.network=network;proxy.destination=s3
    threading.Thread(target=proxy.serve_forever,daemon=True).start()
    env={k:os.environ[k] for k in ('PATH','HOME','TMPDIR','LANG') if k in os.environ};secret=os.urandom(32).hex();token=os.urandom(32).hex()
    serverenv=env.copy();serverenv['RCLONE_AUTH_KEY']='"fixture,'+secret+'"';serverlog=(root/'s3.log').open('wb')
    server=subprocess.Popen([str(args.rclone.resolve()),'serve','s3',str(backend),'--addr',f'127.0.0.1:{s3}','--config','/dev/null'],env=serverenv,stdout=serverlog,stderr=serverlog)
    env.update(STREAMING_CONTROL_TOKEN=token,STREAMING_S3_ACCESS_KEY='fixture',STREAMING_S3_SECRET_KEY=secret)
    engine=None;enginelogs=[];producers=[];cases=[];checks=[];faults=[];success=False;safe=False
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    def api(route='/status',method='GET',timeout=3):
        req=urllib.request.Request(f'http://127.0.0.1:{control}'+route,method=method,headers={'Authorization':'Bearer '+token})
        with opener.open(req,timeout=timeout) as r:return json.load(r)
    def start_engine(crash=False):
        handle=(root/f'engine-{len(enginelogs)}.log').open('wb');enginelogs.append(handle)
        command=[str(binary),'--state',str(state),'--addr',f'127.0.0.1:{nfs}','--control',f'127.0.0.1:{control}','--store','s3','--endpoint',f'http://127.0.0.1:{proxy.server_port}','--bucket','fixture','--prefix','streaming-experiment']
        if crash:command.append('--crash-after-put')
        p=subprocess.Popen(command,env=env,stdout=handle,stderr=handle)
        local.until(lambda:api().get('maxWriteBytes')==MiB,seconds=20);return p
    def mount_fixture():
        assert not local.is_mounted(mount)
        options=f'port={nfs},mountport={nfs},tcp,vers=3,nolocks,mutejukebox,nodev,nosuid,wsize=1048576,rsize=1048576,acregmin=0,acregmax=1'
        if args.faults_only:options+=',soft,timeo=10,retrans=1'
        local.command(['/sbin/mount_nfs','-o',options,'127.0.0.1:/',str(mount)])
    def sample(peaks):
        peaks['stateAllocatedBytes']=max(peaks.get('stateAllocatedBytes',0),allocation(state))
        peaks['engineRSSBytes']=max(peaks.get('engineRSSBytes',0),rss(engine.pid))
        peaks['s3FixtureRSSBytes']=max(peaks.get('s3FixtureRSSBytes',0),rss(server.pid))
    producer_code='''import hashlib,json,os,pathlib,sys,time
path,seedpath,eventspath,count,rate=sys.argv[1:];count=int(count);rate=float(rate);seed=pathlib.Path(seedpath).read_bytes();events={};start=time.monotonic()
with open(path,'xb',buffering=0) as f:
 for i in range(count):
  block=hashlib.shake_256(seed+i.to_bytes(8,'big')).digest(1048576);n=f.write(block);assert n==len(block);os.fsync(f.fileno())
  if i==0:events['firstFsyncReturnedAtEpoch']=time.time()
  events['acceptedMiB']=i+1;pathlib.Path(eventspath).write_text(json.dumps(events))
  time.sleep(max(0,start+(i+1)/rate-time.monotonic()))
events['producerClosedAtEpoch']=time.time();pathlib.Path(eventspath).write_text(json.dumps(events))
'''
    def produce(names,size_mib):
        assert shutil.disk_usage(root).free>4*size_mib*MiB+2*1024*MiB
        before=network.snapshot();network.begin_case();start=time.time();peaks={};members=[]
        for name in names:
            events=root/(name+'.events.json');log=(root/(name+'.producer.log')).open('wb');enginelogs.append(log)
            p=subprocess.Popen([sys.executable,'-c',producer_code,str(mount/name),str(root/'seed.bin'),str(events),str(size_mib),str(args.producer_mib_per_second)],stdout=log,stderr=log);producers.append(p);members.append((name,p,events))
        deadline=time.monotonic()+max(90,len(names)*size_mib/max(args.network_mib_per_second,1)*5)
        seen_during=False;first_committed_while_open=None
        while any(p.poll() is None for _,p,_ in members) and time.monotonic()<deadline:
            sample(peaks);snap=network.snapshot()
            try:
                manifest=json.loads((state/'manifest.json').read_text())
                _,committed=network.user_events(manifest,names)
                if committed is not None:
                    seen_during=True
                    if first_committed_while_open is None:first_committed_while_open=committed
            except (FileNotFoundError,ValueError):pass
            time.sleep(.15)
        assert all(p.poll()==0 for _,p,_ in members),'producer failed/deadline; private fixture retained'
        sample(peaks);after=network.snapshot();events=[json.loads(e.read_text()) for _,_,e in members]
        assert seen_during,'no durable remote chunk commit observed while producer remained open'
        assert all(e['acceptedMiB']==size_mib for e in events)
        assert peaks['stateAllocatedBytes']<256*MiB,'aggregate local-state allocation exceeds prototype disk budget'
        status=api();assert status['payloadStagingBytes']==0 and not status['poisoned']
        first_payload,_=network.user_events(json.loads((state/'manifest.json').read_text()),names)
        row={'names':names,'eachSizeBytes':size_mib*MiB,'elapsedSeconds':round(time.time()-start,3),'firstUserPayloadSeconds':round(first_payload-start,3),'firstCommittedUserChunkWhileProducerOpenSeconds':round(first_committed_while_open-start,3),'producerCloseSeconds':[round(e['producerClosedAtEpoch']-start,3) for e in events],'networkDuringWrites':delta(before,after),'peaks':peaks,'statusAfterWrites':status,'expectedSHA256':expected_digest(seed,size_mib),'publication':'explicit-control-only'}
        cases.append(row);print(json.dumps(row),flush=True);return row
    def publish(name,expected):
        before=network.snapshot();peaks={};result={};start=time.time()
        def work():
            try:result['value']=api('/publish?'+urllib.parse.urlencode({'name':name,'key':'ordinary/'+name}),method='POST',timeout=600)
            except Exception as error:result['error']=str(type(error).__name__)
        thread=threading.Thread(target=work);thread.start()
        while thread.is_alive():sample(peaks);time.sleep(.2)
        thread.join();assert result.get('value',{}).get('published') is True,result
        remote=backend/'fixture/streaming-experiment/ordinary'/name;assert digest(remote)==expected
        after=network.snapshot();changes=delta(before,after)
        assert changes['chunkGetBytes']>=remote.stat().st_size
        assert changes['ordinaryPutBytes']==remote.stat().st_size
        return {'name':name,'elapsedSeconds':round(time.time()-start,3),'independentSHA256':expected,'sizeBytes':remote.stat().st_size,'network':changes,'peaks':peaks}
    try:
        engine=start_engine();mount_fixture();checks.append('isolated authenticated S3-backed engine and native1MiB NFS mount')
        for n in args.sizes_mib:
            row=produce([f'seq-{n}MiB.bin'],n)
            # The producer fsync has returned, so accepted bytes must survive process restart.
            local.command(['/sbin/umount',str(mount)]);engine.terminate();engine.wait(timeout=10);engine=start_engine();mount_fixture()
            name=row['names'][0]
            local.command([sys.executable,'-c','import hashlib,pathlib,sys;seed=pathlib.Path(sys.argv[2]).read_bytes();p=open(sys.argv[1],"rb");expected=hashlib.shake_256(seed+(0).to_bytes(8,"big")).digest(1048576);assert p.read(1048576)==expected',str(mount/name),str(root/'seed.bin')],timeout=30)
            checks.append(f'{n}MiB fsync-accepted prefix survives engine process restart and cold NFS remount')
            # Drain kernel read-ahead before measuring assembly-only GET traffic.
            local.command(['/sbin/umount',str(mount)])
            row['ordinaryPublication']=publish(name,row['expectedSHA256']);mount_fixture()
        if args.concurrent_mib:
            row=produce(['concurrent-a.bin','concurrent-b.bin'],args.concurrent_mib)
            row['ordinaryPublications']=[publish(name,row['expectedSHA256']) for name in row['names']]
        # Native mutation semantics on a small independent fixture.
        row=produce(['mutate.bin'],8)
        local.command([sys.executable,'-c','import os,sys;f=open(sys.argv[1],"r+b",buffering=0);f.seek(1048576-16);f.write(b"R"*32);os.fsync(f.fileno());f.truncate(3*1048576+7);os.fsync(f.fileno());f.seek(1048576-16);assert f.read(32)==b"R"*32;f.close()',str(mount/'mutate.bin')],timeout=30)
        body=bytearray().join(hashlib.shake_256(seed+i.to_bytes(8,'big')).digest(MiB) for i in range(4));body[MiB-16:MiB+16]=b'R'*32;expected=hashlib.sha256(body[:3*MiB+7]).hexdigest()
        row['ordinaryPublication']=publish('mutate.bin',expected);checks.append('native cross-chunk rewrite, explicit truncate and publication preserve independent expected bytes')
        if args.faults_only:
            # O_SYNC prevents a returned buffered userspace write being mistaken for
            # stable NFS acknowledgement. These are disposable soft-mount tests only.
            fault_writer='''import json,os,sys
r={'writeReturnedBytes':0,'fsyncSucceeded':False};fd=None
try:
 fd=os.open(sys.argv[1],os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_SYNC,0o600)
 r['writeReturnedBytes']=os.write(fd,b'Q'*1048576);os.fsync(fd);r['fsyncSucceeded']=True
except OSError as e:r['errno']=e.errno
finally:
 if fd is not None:
  try:os.close(fd)
  except OSError:pass
print(json.dumps(r))
'''
            def verify_prefix():
                # Fresh mount ensures the kernel cannot supply old cached bytes.
                output=local.command([sys.executable,'-c','import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())',str(mount/'mutate.bin')],timeout=30)
                assert output.strip()==expected
            before=api();before_net=network.snapshot();network.offline=True;started=time.time();peaks={}
            outcome=json.loads(local.command([sys.executable,'-c',fault_writer,str(mount/'outage.bin')],timeout=20));sample(peaks)
            assert not outcome['fsyncSucceeded'] and 'errno' in outcome,outcome
            after=api();assert after['acceptedBytes']==before['acceptedBytes']
            manifest=json.loads((state/'manifest.json').read_text());assert manifest['Files'].get('outage.bin',{}).get('Size',0)==0
            assert not (backend/'fixture/streaming-experiment/ordinary/outage.bin').exists()
            # Keep endpoint unavailable during normal unmount so it cannot silently
            # turn the failed candidate into a later acknowledged success.
            local.command(['/sbin/umount',str(mount)],timeout=20);engine.terminate();engine.wait(timeout=10)
            network.offline=False;engine=start_engine();mount_fixture();verify_prefix()
            assert api()['acceptedBytes']==before['acceptedBytes']
            restored=publish('mutate.bin',expected)
            faults.append({'kind':'remote503','elapsedSeconds':round(time.time()-started,3),'synchronousWriteOutcome':outcome,'acceptedBytesBefore':before['acceptedBytes'],'acceptedBytesAfterRestart':api()['acceptedBytes'],'failedCandidateSizeBytes':0,'peaks':peaks,'acceptedPrefixRepublished':restored,'network':delta(before_net,network.snapshot())})
            checks.append('S3 outage causes bounded synchronous write/flush error; no candidate journal advance; accepted prefix matches after restart')
            local.command(['/sbin/umount',str(mount)]);engine.terminate();engine.wait(timeout=10);engine=start_engine(crash=True)
            before=json.loads((state/'manifest.json').read_text());before_net=network.snapshot();started=time.time()
            wire=WireNFS(nfs);handle=wire.handle('outage.bin');assert wire.size(handle)==0
            try:
                wire.call(100003,7,opaque(handle)+struct.pack('!QII',0,MiB,2)+opaque(b'Q'*MiB))
            except EOFError:outcome={'rpcReplyReceived':False,'stableWriteAcknowledged':False,'transport':'bounded-direct-NFSv3-FILE_SYNC'}
            else:raise AssertionError('crash candidate unexpectedly received RPC acknowledgement')
            local.until(lambda:engine.poll() is not None,seconds=5);assert engine.returncode==86
            after=json.loads((state/'manifest.json').read_text());assert after['AcceptedBytes']==before['AcceptedBytes']
            assert after['Files'].get('outage.bin',{}).get('Size',0)==0
            assert network.snapshot()['chunkCommitResponses']>before_net['chunkCommitResponses']
            engine=start_engine();assert WireNFS(nfs).read_digest('mutate.bin')==expected;mount_fixture();verify_prefix()
            assert api()['acceptedBytes']==before['AcceptedBytes']
            assert not (backend/'fixture/streaming-experiment/ordinary/outage.bin').exists()
            restored=publish('mutate.bin',expected)
            faults.append({'kind':'exit86afterRemotePutBeforeJournal','elapsedSeconds':round(time.time()-started,3),'writeOutcome':outcome,'acceptedBytesBefore':before['AcceptedBytes'],'acceptedBytesAfterRestart':api()['acceptedBytes'],'failedCandidateSizeBytes':0,'acceptedPrefixRepublished':restored,'network':delta(before_net,network.snapshot())})
            checks.append('remote chunk PUT succeeded before injected exit86; candidate never journaled/acknowledged/published; accepted prefix matches after restart')
        local.command(['/sbin/umount',str(mount)]);engine.terminate();engine.wait(timeout=10);server.terminate();server.wait(timeout=10);success=True
    finally:
        try:
            for p in producers:
                if p.poll() is None:p.terminate();p.wait(timeout=5)
            if local.is_mounted(mount):local.command(['/sbin/umount',str(mount)])
            if not local.is_mounted(mount):
                if engine and engine.poll() is None:engine.terminate();engine.wait(timeout=10)
                if server.poll() is None:server.terminate();server.wait(timeout=10)
                safe=(engine is None or engine.poll() is not None) and server.poll() is not None
        except Exception:pass
        proxy.shutdown();proxy.server_close();serverlog.close()
        for handle in enginelogs:handle.close()
        report={'experimental':True,'success':success,'safeShutdown':safe,'softMountFaultFixture':args.faults_only,'engineSHA256':digest(binary),'rcloneSHA256':digest(args.rclone.resolve()),'producerMiBPerSecond':args.producer_mib_per_second,'networkMiBPerSecondPerRequest':args.network_mib_per_second,'proposedAggregateDiskBudgetBytes':256*MiB,'checks':checks,'cases':cases,'faults':faults,'networkTotals':network.snapshot(),'fixtureRetained':None if success and safe else str(root)}
        args.report.write_text(json.dumps(report,indent=2)+'\n');print('Report: '+str(args.report),flush=True)
        if success and safe:shutil.rmtree(root)
        else:print('Retained generated fixture; never remove while mounted: '+str(root),file=sys.stderr)
if __name__=='__main__':main()
