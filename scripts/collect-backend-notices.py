#!/usr/bin/env python3
"""Collect backend notices and a self-contained corresponding-source archive."""
import argparse
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent
TOOL = 'github.com/google/go-licenses/v2@v2.0.1'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def collect(go, source, backend, output):
    if output.exists():
        raise RuntimeError('Notice output already exists; preserve it or select a new output directory.')
    env = dict(os.environ, PATH=str(go.parent)+os.pathsep+os.environ.get('PATH', ''),
               GOTOOLCHAIN='local', GOMAXPROCS='2', CGO_ENABLED='0', GOFLAGS='-mod=mod')
    with tempfile.TemporaryDirectory(prefix='clouddrive-notice-tool-') as temporary:
        env['GOBIN'] = temporary
        subprocess.run([str(go), 'install', TOOL], env=env, check=True)
        tool = str(Path(temporary)/'go-licenses')
        subprocess.run([tool, 'save', '.', '--save_path', str(output)], cwd=source, env=env, check=True)
        report = subprocess.run([tool, 'report', '.'], cwd=source, env=env, capture_output=True, text=True, check=True)
        rows = list(csv.reader(io.StringIO(report.stdout)))
        if not rows or any(len(row) != 3 or not row[2] or row[2] == 'Unknown' for row in rows):
            raise RuntimeError('Unclassified backend dependency license; release stopped.')
        for row in rows:
            if row[0] == 'github.com/rclone/rclone':
                row[1] = 'https://github.com/rclone/rclone/blob/v1.75.2/LICENSE'
            if row[0] == 'github.com/willscott/go-nfs':
                row[1] = 'https://github.com/willscott/go-nfs/blob/v0.0.4/LICENSE'
        for row in rows:
            if row[1] in ('', 'Unknown'):
                bundled = output/row[0]/'LICENSE'
                if not bundled.is_file():
                    raise RuntimeError('Missing license for '+row[0])
                row[1] = 'bundled:'+str(bundled.relative_to(output))
        with (output/'LICENSES.csv').open('w') as f:
            writer = csv.writer(f); writer.writerow(['library', 'upstream_license_url', 'license']); writer.writerows(rows)
    shutil.copy2(go.parent.parent/'LICENSE', output/'GO-TOOLCHAIN-LICENSE.txt')
    for name in ['GPL-3.0.txt', 'LGPL-3.0.txt']:
        shutil.copy2(ROOT/'vendor'/name, output/name)
    shutil.copy2(ROOT/'vendor/THIRD_PARTY_CHANGES.md', output/'BACKEND_CHANGES.md')
    (output/'README.txt').write_text(
        'CloudDrive backend third-party notices\n\n'
        'LICENSES.csv identifies libraries and licenses. Subdirectories retain their license, copyright, '
        'NOTICE and source materials. Upstream licenses govern each component, including MPL-2.0 and LGPL-3.0 components.\n\n'
        'The matching CloudDrive GitHub Release includes backend-source.tar.gz with the patched rclone '
        'source, vendored dependencies, license materials and rebuild instructions. It permits rebuilding '
        'with modified libraries. No additional restriction on modification or reverse engineering is imposed. '
        'CloudDrive-authored code is MIT licensed; third-party licenses are not replaced.\n'
    )
    # Full vendored sources allow rebuilding the static Go executable with modified libraries.
    subprocess.run([str(go), 'mod', 'vendor'], cwd=source, env=env, check=True)
    source_archive = output.parent/'backend-source.tar.gz'
    with tempfile.TemporaryDirectory(prefix='clouddrive-source-notice-') as temporary:
        extra = Path(temporary)
        for name in ['GPL-3.0.txt', 'LGPL-3.0.txt']:
            shutil.copy2(ROOT/'vendor'/name, extra/name)
        shutil.copy2(ROOT/'vendor/RCLONE_BUILD.json', extra/'RCLONE_BUILD.json')
        shutil.copy2(ROOT/'vendor/THIRD_PARTY_CHANGES.md', extra/'THIRD_PARTY_CHANGES.md')
        shutil.copytree(ROOT/'vendor/patches', extra/'patches')
        version = json.loads((ROOT/'vendor/RCLONE_BUILD.json').read_text())['version']
        link_flags = shlex.quote('-s -w -X github.com/rclone/rclone/fs.Version='+version)
        (extra/'BUILD.sh').write_text('#!/bin/sh\nset -eu\ncd "$(dirname "$0")/rclone"\n'
            'export CGO_ENABLED=0 GOTOOLCHAIN=local\n'
            f'go build -mod=vendor -trimpath -ldflags {link_flags} -o ../rclone-rebuilt .\n')
        (extra/'README.txt').write_text('Corresponding source for the CloudDrive rclone backend.\n'
            'Install Go 1.27.3 from go.dev, then run sh BUILD.sh. Vendored Go dependencies are included.\n'
            'RCLONE_BUILD.json pins upstream source/toolchain hashes. Patches are already applied.\n'
            'Third-party sources retain their own licenses. You may modify and rebuild the libraries/backend.\n'
            'The rebuilt backend is unsigned. To run it in CloudDrive, build CloudDrive source using '
            'CLOUDDRIVE_BACKEND pointing to rclone-rebuilt and sign with your own certificate as described in docs/DEVELOPMENT.md.\n')
        def normalized(info):
            info.uid = info.gid = 0; info.uname = info.gname = ''; info.mtime = 0
            return info
        with tarfile.open(source_archive, 'w:gz') as archive:
            archive.add(source, arcname='backend-source/rclone', filter=normalized)
            archive.add(source.parent/'go-nfs', arcname='backend-source/go-nfs', filter=normalized)
            for path in sorted(extra.iterdir()):
                archive.add(path, arcname='backend-source/'+path.name, filter=normalized)
    manifest = {'tool': TOOL, 'backendSHA256': digest(backend), 'libraries': len(rows),
                'sourceArchiveSHA256': digest(source_archive),
                'files': {str(p.relative_to(output)): digest(p) for p in sorted(output.rglob('*')) if p.is_file()}}
    (output/'MANIFEST.json').write_text(json.dumps(manifest, indent=2)+'\n')
    print(f'Collected {len(rows)} libraries, notices and corresponding source.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['go', 'source', 'backend', 'output']:
        parser.add_argument('--'+name, required=True, type=Path)
    args = parser.parse_args()
    collect(*(getattr(args, name).resolve() for name in ['go', 'source', 'backend', 'output']))
