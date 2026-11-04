#!/usr/bin/env python3
"""Rebuild the pinned local-allocation backend into build/backend/rclone.

Uses a private temporary toolchain, sources, module/cache directories. It never
replaces a bundled binary or accesses a drive/profile/bucket. Downloads are
verified against vendor/RCLONE_BUILD.json before extraction.
"""
import hashlib, json, os, pathlib, shutil, subprocess, sys, tarfile, tempfile, urllib.request
ROOT=pathlib.Path(__file__).resolve().parent.parent
INFO=json.loads((ROOT/'vendor/RCLONE_BUILD.json').read_text())
def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for part in iter(lambda:f.read(1048576),b''):h.update(part)
    return h.hexdigest()
def unpack(archive, target):
    target.mkdir()
    with tarfile.open(archive,'r:gz') as tar:
        for member in tar.getmembers():
            parts=pathlib.PurePosixPath(member.name).parts
            if not parts or pathlib.PurePosixPath(member.name).is_absolute() or '..' in parts or not (member.isdir() or member.isfile()):
                raise RuntimeError('Unsafe source archive entry')
            relative=parts[1:]
            if not relative:continue
            path=target.joinpath(*relative)
            if member.isdir():path.mkdir(parents=True,exist_ok=True)
            else:
                path.parent.mkdir(parents=True,exist_ok=True)
                with tar.extractfile(member) as src,path.open('xb') as dest:shutil.copyfileobj(src,dest)
                path.chmod(member.mode & 0o777)
def cleanup(root):
    for directory, dirs, files in os.walk(root,followlinks=False):
        os.chmod(directory,0o700)
        for name in files:
            path=pathlib.Path(directory)/name
            if not path.is_symlink():path.chmod(path.stat().st_mode|0o600)
    shutil.rmtree(root)
def main():
    stage=pathlib.Path(tempfile.mkdtemp(prefix='clouddrive-backend-build-'))
    try:
        for source in INFO['sources']:
            archive=stage/(source['name']+'.tar.gz')
            with urllib.request.urlopen(source['url'],timeout=60) as src,archive.open('wb') as dest:shutil.copyfileobj(src,dest)
            if sha(archive)!=source['sha256']:raise RuntimeError('Source checksum mismatch: '+source['name'])
            unpack(archive,stage/source['name'])
        for patch,base in [('0001-go-nfs-local-allocation.patch','go-nfs'),('0002-rclone-local-allocation.patch','rclone')]:
            file=ROOT/'vendor/patches'/patch
            if sha(file)!=INFO['patches'][patch]:raise RuntimeError('Patch checksum mismatch')
            subprocess.run(['/usr/bin/patch','-p1','-i',str(file)],cwd=stage/base,check=True)
        go=str(stage/'go/bin/go')
        env={'PATH':str(stage/'go/bin')+':/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(pathlib.Path.home()),
             'GOTOOLCHAIN':'local','GOMAXPROCS':'2','GOPATH':str(stage/'modules'),'GOCACHE':str(stage/'compile-cache'),'CGO_ENABLED':'0'}
        subprocess.run([go,'mod','edit','-replace','github.com/willscott/go-nfs=../go-nfs'],cwd=stage/'rclone',env=env,check=True)
        subprocess.run([go,'test','-p','2','./...','-run','TestOptionalAllocatedBytes','-count=1'],cwd=stage/'go-nfs',env=env,check=True)
        subprocess.run([go,'test','-p','2','./cmd/serve/nfs','./vfs/vfscache','-run','TestAllocation|TestAllocated','-count=1'],cwd=stage/'rclone',env=env,check=True)
        out=ROOT/'build/backend/rclone';out.parent.mkdir(parents=True,exist_ok=True)
        subprocess.run([go,'build','-p','2','-trimpath','-ldflags','-s -w -X github.com/rclone/rclone/fs.Version='+INFO['version'],'-o',str(out),'.'],cwd=stage/'rclone',env=env,check=True)
        notices=out.parent/'backend-notices'
        if notices.exists():shutil.rmtree(notices)
        subprocess.run([sys.executable,str(ROOT/'scripts/collect-backend-notices.py'),'--go',go,'--source',str(stage/'rclone'),'--backend',str(out),'--output',str(notices)],env=env,check=True)
        print(out)
        print('Run qualification before explicitly selecting this backend for packaging.')
    finally:cleanup(stage)
if __name__=='__main__':main()
