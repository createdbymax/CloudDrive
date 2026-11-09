#!/usr/bin/env python3
"""macOS host regression for a refused normal eject of CloudDrive's installed NFS drive.

Only --exercise-busy-eject attempts an unmount. --check-only performs the
signed-host/worker and idle checks. The generated local report contains no
credentials, remote names, mount paths or directory listings.
"""
import argparse
import base64
import contextlib
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import selectors
import subprocess
import sys
import tempfile
import time
import urllib.request

APP = Path('/Applications/CloudDrive.app')
DATA = Path.home() / 'Library/Application Support/BucketDrive'
GUARD = r"""
#include <sys/mount.h>
#include <sys/types.h>
#include <fcntl.h>
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static int match(const struct statfs *s,const char *path,const char *id){
 char value[64];snprintf(value,sizeof value,"%d:%d",s->f_fsid.val[0],s->f_fsid.val[1]);
 return !strcmp(s->f_mntonname,path)&&!strcmp(s->f_mntfromname,"127.0.0.1:/")&&!strcmp(s->f_fstypename,"nfs")&&!strcmp(value,id);
}
int main(int argc,char **a){
 if(argc!=9)return 2;
 int n=getfsstat(NULL,0,MNT_NOWAIT);if(n<1)return 3;
 struct statfs *table=calloc(n+32,sizeof(*table));if(!table)return 3;
 int k=getfsstat(table,(int)((n+32)*sizeof(*table)),MNT_NOWAIT);if(k<1||k>=n+32)return 3;
 int count=0;for(int i=0;i<k;i++)if(match(&table[i],a[2],a[3]))count++;free(table);if(count!=1)return 4;
 struct proc_bsdinfo p;char exe[PROC_PIDPATHINFO_MAXSIZE];pid_t pid=atoi(a[4]);
 if(pid<2||proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&p,sizeof p)!=sizeof p||proc_pidpath(pid,exe,sizeof exe)<=0)return 5;
 if(p.pbi_uid!=getuid()||p.pbi_uid!=strtoul(a[5],NULL,10)||p.pbi_start_tvsec!=strtoull(a[6],NULL,10)||p.pbi_start_tvusec!=strtoull(a[7],NULL,10)||strcmp(exe,a[8]))return 5;
 if(!strcmp(a[1],"check"))return 0;if(strcmp(a[1],"hold"))return 2;
 int fd=open(a[2],O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);struct statfs s;
 if(fd<0||fstatfs(fd,&s)||!match(&s,a[2],a[3])||fchdir(fd))return 6;
 if(write(STDOUT_FILENO,"READY\n",6)!=6)return 7;
 char byte;while(read(STDIN_FILENO,&byte,1)>0){}
 return close(fd)!=0;
}
"""


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def execute(args, *, seconds=15, stdin=None):
    return subprocess.run(args, input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          timeout=seconds, env={**os.environ, 'LC_ALL': 'C'})


def compile_guard(folder):
    src = folder / 'identity.c'
    binary = folder / 'identity'
    src.write_text(GUARD)
    require(execute(['/usr/bin/cc', '-O2', '-Wall', '-Wextra', '-Werror', str(src), '-o', str(binary)],
                    seconds=30).returncode == 0, 'Compiled host identity check failed')
    return binary


def signed_install(expected):
    info = plistlib.loads((APP / 'Contents/Info.plist').read_bytes())
    require(info['CFBundleIdentifier'] == 'local.bucketdrive.app' and
            str(info['CFBundleVersion']) == str(expected), 'Installed build does not match requested build')
    require(execute(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(APP)], seconds=90).returncode == 0,
            'Installed bundle signature verification failed')
    detail = execute(['/usr/bin/codesign', '-dv', '--verbose=4', str(APP)])
    require(detail.returncode == 0 and b'TeamIdentifier=EGEBBVL76D' in detail.stderr.splitlines(),
            'Unexpected installed team signature')


def host_identity():
    result = execute(['/bin/ps', '-axo', 'pid=,comm='])
    require(result.returncode == 0, 'Cannot enumerate running host')
    target = str(APP / 'Contents/MacOS/CloudDrive')
    pids = [int(row.split(None, 1)[0]) for row in os.fsdecode(result.stdout).splitlines()
            if len(row.split(None, 1)) == 2 and row.split(None, 1)[1] == target]
    require(len(pids) == 1, 'Expected exactly one running installed host')
    started = execute(['/bin/ps','-p',str(pids[0]),'-o','lstart='])
    require(started.returncode == 0 and started.stdout.strip(), 'Running host identity unavailable')
    return pids[0], started.stdout.strip()


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def load_worker():
    saved = DATA / 'worker.json'
    require(saved.is_file() and not saved.is_symlink(), 'Worker record unavailable')
    record = json.loads(saved.read_bytes())
    mount = Path(record['mountPath'])
    require(mount == DATA / 'Drive' and not mount.is_symlink(), 'Unexpected personal mount path')
    process = record['process']
    exe = Path(process['executablePath'])
    require(exe.name == 'rclone' and exe.parent.parent == DATA / 'Workers' and
            re.fullmatch(r'[a-f0-9]{64}', exe.parent.name) and exe.resolve(strict=True) == exe
            and process['uid'] == os.getuid(), 'Unexpected worker path or owner')
    require(digest(exe) == digest(APP / 'Contents/Resources/rclone'), 'Running worker differs from bundled worker')
    return record


def busy_result(result):
    # Darwin umount formats its ordinary EBUSY as "Resource busy".
    return result.returncode > 0 and bool(re.search(rb'\bresource busy\b', result.stderr, re.I))


def call(record, route):
    token = base64.b64encode(('bucketdrive:' + record['controlToken']).encode()).decode()
    request = urllib.request.Request('http://127.0.0.1:' + str(int(record['controlPort'])) + '/' + route,
                                     data=b'{}', headers={'Content-Type':'application/json',
                                                          'Authorization':'Basic '+token})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(request, timeout=5) as response:
        return json.load(response)


def check(record, guard, host, *, idle=False):
    require(host_identity() == host, 'Installed host stopped or restarted')
    current = json.loads((DATA / 'worker.json').read_bytes())
    fields = ('process','mountID','mountPath','sessionID','destinationFingerprint',
              'controlPort','nfsPort','controlToken','observedFS','observedCachePath')
    require(all(record.get(k) == current.get(k) for k in fields), 'Saved session identity changed')
    require(execute([*guard[:1],'check',*guard[1:]], seconds=5).returncode == 0, 'Worker or NFS mount identity changed')
    require(call(record,'core/pid').get('pid') == record['process']['pid'], 'Control peer identity changed')
    stats = call(record,'vfs/stats')
    disk = stats['diskCache']
    require(stats.get('fs') == record['observedFS'] and disk.get('path') == record['observedCachePath'],
            'Worker cache or remote identity changed')
    if idle:
        moves = call(record,'vfs/moves')
        require(moves.get('active') is False and moves.get('needsRecovery') is False
                and disk.get('outOfSpace') is False
                and all(type(disk.get(k)) == int and disk[k] == 0
                        for k in ('uploadsQueued','uploadsInProgress','erroredFiles'))
                and call(record,'vfs/queue').get('queue','missing') in (None,[]),
                'Move, recovery, upload or storage activity prevents eject qualification')


@contextlib.contextmanager
def hold_directory(guard):
    # A separate process keeps BOTH a verified O_RDONLY directory descriptor
    # and its working directory on the exact selected NFS filesystem.
    holder = subprocess.Popen([*guard[:1],'hold',*guard[1:]], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, bufsize=0)
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(holder.stdout,selectors.EVENT_READ)
            require(selector.select(8) and holder.stdout.readline(8) == b'READY\n' and holder.poll() is None,
                    'Verified directory holder could not acquire mount')
        yield holder
    finally:
        holder.stdin.close()
        try:
            holder.wait(timeout=8)
        except subprocess.TimeoutExpired:
            holder.kill()  # Only our own descriptor-holder child.
            holder.wait(timeout=8)
        holder.stdout.close()


def finder_count(mount):
    script = '''on run argv
    set targetFolder to (POSIX file (item 1 of argv)) as alias
    set hfsPath to targetFolder as text
    tell application id "com.apple.finder" to return count of items of folder hfsPath
end run'''
    result = execute(['/usr/bin/osascript','-e',script,str(mount)],seconds=30)
    require(result.returncode == 0 and re.fullmatch(rb'[0-9]+',result.stdout.strip()),
            'Finder directory enumeration failed or Apple Events access was unavailable')


def qualify(args, result):
    signed_install(args.expected_build)
    host = host_identity()
    record = load_worker()
    process = record['process']
    with tempfile.TemporaryDirectory(prefix='clouddrive-busy-eject-') as temp:
        binary = compile_guard(Path(temp))
        guard = [str(binary),record['mountPath'],record['mountID'],str(process['pid']),str(process['uid']),
                 str(process['startSeconds']),str(process['startMicroseconds']),process['executablePath']]
        check(record,guard,host,idle=True)
        result['identityAndIdleVerified'] = True
        if args.check_only:
            return
        finder_count(record['mountPath'])  # Fail before umount if this host cannot observe Finder.
        result['finderReadBefore'] = True
        with hold_directory(guard) as holder:
            check(record,guard,host,idle=True)
            require(holder.poll() is None, 'Directory holder exited prematurely')
            eject = execute(['/sbin/umount',record['mountPath']],seconds=20)
            result['umountExit'] = eject.returncode
            require(busy_result(eject), 'Normal unmount did not return the expected Resource busy refusal')
            result['normalEjectBusy'] = True
            until = time.monotonic() + args.observe_seconds
            samples = 0
            while True:
                check(record,guard,host)
                require(holder.poll() is None, 'Directory holder exited before observations finished')
                samples += 1
                remaining = until - time.monotonic()
                if remaining <= 0:
                    break
                time.sleep(min(1,remaining))
            result['identitySamplesDuringHold'] = samples
            result['observedSeconds'] = args.observe_seconds
        finder_count(record['mountPath'])
        result['finderReadAfterRelease'] = True
        check(record,guard,host,idle=True)
        result['sameSessionAfterRelease'] = True


def main():
    p = argparse.ArgumentParser(description=__doc__)
    mode = p.add_mutually_exclusive_group(required=True)
    mode.add_argument('--check-only',action='store_true')
    mode.add_argument('--exercise-busy-eject',action='store_true')
    mode.add_argument('--self-test',action='store_true')
    p.add_argument('--expected-build',type=int,default=32)
    p.add_argument('--observe-seconds',type=int,default=20,choices=range(12,121),metavar='12..120')
    p.add_argument('--report',type=Path)
    a = p.parse_args()
    os.umask(0o077)
    if a.self_test:
        with tempfile.TemporaryDirectory() as temp:
            binpath = compile_guard(Path(temp))
            require(execute([str(binpath),'hold',temp,'1:2','1','0','0','0','/invalid']).returncode == 4,
                    'Guard accepted a non-mount')
        require(busy_result(subprocess.CompletedProcess([],1,b'',b'umount: Resource busy')) and
                not busy_result(subprocess.CompletedProcess([],0,b'',b'')) and
                not busy_result(subprocess.CompletedProcess([],1,b'',b'permission denied')), 'Diagnostic classification failed')
        print('Self-test passed. No unmount attempted.')
        return
    require(a.report is not None, 'Pass --report for local evidence')
    report = a.report.expanduser().resolve()
    # Reports must stay off the personal mount, even when invoked through a symlink.
    require(not report.is_relative_to((DATA/'Drive').resolve()), 'Report must be on local storage')
    result = {'build':a.expected_build,'mode':'read-only preflight' if a.check_only else 'normal busy eject',
              'passed':False,'startedAt':time.time()}
    try:
        qualify(a,result)
        result['passed'] = True
    finally:
        result['finishedAt'] = time.time()
        report.parent.mkdir(parents=True,exist_ok=True)
        report.write_text(json.dumps(result,indent=2)+'\n')
        print(json.dumps(result))


if __name__ == '__main__':
    main()
