#!/usr/bin/env python3
"""Build the isolated streaming experiment; never packages or starts CloudDrive."""
import argparse
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import tarfile
import tempfile

HERE=pathlib.Path(__file__).resolve().parent
ROOT=HERE.parents[1]

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--go',type=pathlib.Path,help='Existing pinned Go executable')
    parser.add_argument('--toolchain-archive',type=pathlib.Path,help='Pinned Go archive; verified against vendor/RCLONE_BUILD.json')
    parser.add_argument('--test',action='store_true',help='Run experiment unit/S3 adapter tests before building')
    args=parser.parse_args()
    source=next(x for x in json.loads((ROOT/'vendor/RCLONE_BUILD.json').read_text())['sources'] if x['name']=='go')
    toolroot=None
    try:
        if args.go:
            go=args.go.resolve(strict=True)
        else:
            if args.toolchain_archive is None:
                parser.error('Provide --go /path/to/go or --toolchain-archive /path/to/the/pinned/archive')
            archive=args.toolchain_archive
            if hashlib.sha256(archive.read_bytes()).hexdigest()!=source['sha256']:raise RuntimeError('Pinned toolchain archive checksum mismatch')
            toolroot=pathlib.Path(tempfile.mkdtemp(prefix='clouddrive-streaming-build-'))
            toolroot.chmod(0o700)
            with tarfile.open(archive,'r:gz') as tar:
                for item in tar.getmembers():
                    parts=pathlib.PurePosixPath(item.name).parts
                    if pathlib.PurePosixPath(item.name).is_absolute() or '..' in parts or not(item.isfile()or item.isdir()):raise RuntimeError('Unsafe toolchain entry')
                    path=toolroot.joinpath(*parts)
                    if item.isdir():path.mkdir(parents=True,exist_ok=True)
                    else:
                        path.parent.mkdir(parents=True,exist_ok=True)
                        path.write_bytes(tar.extractfile(item).read());path.chmod(item.mode&0o777)
            go=toolroot/'go/bin/go'
        cache=pathlib.Path(tempfile.gettempdir())/'clouddrive-streaming-build-cache';cache.mkdir(exist_ok=True);cache.chmod(0o700)
        env={key:os.environ[key] for key in ('HOME','TMPDIR','LANG') if key in os.environ}
        env.update(PATH=str(go.parent)+':/usr/bin:/bin:/usr/sbin:/sbin',GOTOOLCHAIN='local',GOPATH=str(cache/'modules'),GOCACHE=str(cache/'compile'),GOMAXPROCS='2',CGO_ENABLED='0')
        version=subprocess.check_output([str(go),'version'],env=env,text=True).strip()
        if 'go1.27.3 ' not in version:raise RuntimeError('Use pinned Go1.27.3 for this experiment')
        if args.test:
            subprocess.run([str(go),'test','./...','-count=1'],cwd=HERE,env=env,check=True,timeout=180)
            subprocess.run([str(go),'test','-run','TestBoundedOpaque|TestHeaderBound|TestOversizedRPC','-count=1','.'],cwd=HERE/'third_party_go_nfs',env=env,check=True,timeout=180)
        output=HERE/'bin/streaming-nfs';output.parent.mkdir(exist_ok=True)
        subprocess.run([str(go),'build','-trimpath','-o',str(output),'.'],cwd=HERE,env=env,check=True,timeout=180)
        sources=sorted([*HERE.glob('*.go'), *HERE.glob('third_party_go_nfs/**/*.go'), HERE/'go.mod', HERE/'go.sum', HERE/'build.py'])
        manifest={'experimental':True,'goVersion':version,'cgoEnabled':False,
                  'binarySHA256':hashlib.sha256(output.read_bytes()).hexdigest(),
                  'sources':{str(p.relative_to(HERE)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
                  'ownerDataAccessed':False}
        (output.parent/'build-info.json').write_text(json.dumps(manifest,indent=2)+'\n')
        print(output)
        print('EXPERIMENT ONLY. No owner worker, mount, profile or bucket was accessed.')
    finally:
        if toolroot is not None:
            shutil.rmtree(toolroot)

if __name__=='__main__':main()
