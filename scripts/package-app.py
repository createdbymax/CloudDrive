#!/usr/bin/env python3
"""Assemble and sign the same complete app from SwiftPM or Xcode products."""
import datetime
import hashlib
import json
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys
import signing
from sparkle_config import update_metadata, configured_environment

ROOT = pathlib.Path(__file__).resolve().parent.parent


def check_inactive(app):
    processes = subprocess.check_output(['/bin/ps', '-axo', 'comm='], text=True).splitlines()
    owned = {str(app/'Contents/MacOS/CloudDrive'), str(app/'Contents/Resources/rclone'),
             str(app/'Contents/Resources/CloudDriveHelper')}
    if any(line.strip() in owned for line in processes):
        raise RuntimeError('This build is active. Eject its drive and quit it before rebuilding.')


def validate_backend_notices(backend):
    notices = backend.parent/'backend-notices'
    manifest = json.loads((notices/'MANIFEST.json').read_text())
    if hashlib.sha256(backend.read_bytes()).hexdigest() != manifest['backendSHA256']:
        raise RuntimeError('Backend notices do not match this executable. Rebuild the backend.')
    if not {'GPL-3.0.txt', 'LGPL-3.0.txt'}.issubset(manifest['files']):
        raise RuntimeError('Required GNU license materials are missing. Rebuild the backend notices.')
    for name, digest in manifest['files'].items():
        if pathlib.PurePosixPath(name).is_absolute() or '..' in pathlib.PurePosixPath(name).parts:
            raise RuntimeError('Invalid backend notice path.')
        if hashlib.sha256((notices/name).read_bytes()).hexdigest() != digest:
            raise RuntimeError('Backend notice checksum mismatch.')
    return notices


def package(app, products, backend):
    metadata = update_metadata(configured_environment(os.environ))
    check_inactive(app)
    if not backend.is_file() or not os.access(backend, os.X_OK):
        raise RuntimeError('Build the backend first: python3 scripts/build-rclone-allocation.py')
    notices = validate_backend_notices(backend)
    resources = app/'Contents/Resources'
    resources.mkdir(parents=True, exist_ok=True)
    notice_target = resources/'BackendNotices'
    if notice_target.exists():shutil.rmtree(notice_target)
    shutil.copytree(notices, notice_target)
    (app/'Contents/MacOS').mkdir(parents=True, exist_ok=True)
    subprocess.run([sys.executable, str(ROOT/'scripts/build-icon.py')], check=True)
    shutil.copy2(ROOT/'build/icons/CloudDrive.icns', resources/'CloudDrive.icns')
    # Xcode links directly into the bundle; SwiftPM emits a standalone executable.
    executable = products/'CloudDrive'
    if not executable.exists():
        executable = app/'Contents/MacOS/CloudDrive'
    copies = [(executable, app/'Contents/MacOS/CloudDrive'),
              (products/'CloudDriveHelper', resources/'CloudDriveHelper'),
              (backend, resources/'rclone'), (ROOT/'LICENSE', resources/'CloudDrive-LICENSE.txt')]
    copies += [(ROOT/'vendor'/name, resources/name) for name in
               ['RCLONE-LICENSE.txt', 'GO-NFS-LICENSE.txt', 'THIRD_PARTY_CHANGES.md', 'RCLONE_BUILD.json']]
    for source, destination in copies:
        if source.resolve() != destination.resolve():
            shutil.copy2(source, destination)
    # Both build systems resolve the same pinned binary package. Preserve framework symlinks.
    candidates = [products/'Sparkle.framework']
    artifact_roots = [ROOT/'.build/artifacts', products.parent.parent/'artifacts']
    if os.environ.get('SOURCE_PACKAGES_DIR_PATH'):
        artifact_roots.append(pathlib.Path(os.environ['SOURCE_PACKAGES_DIR_PATH'])/'artifacts')
    # Xcode's SourcePackages is adjacent to Build in a derived data directory.
    artifact_roots.append(products.parent.parent.parent/'SourcePackages/artifacts')
    for root in artifact_roots:
        candidates.extend(root.glob('sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'))
    framework = next((p for p in candidates if p.is_dir()), None)
    if framework is None:
        raise RuntimeError('Resolved Sparkle.framework not found. Resolve package dependencies first.')
    destination = app/'Contents/Frameworks/Sparkle.framework'
    if framework.resolve() != destination.resolve():
        if destination.exists(): shutil.rmtree(destination)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(framework, destination, symlinks=True)
    license_file = ROOT/'vendor/SPARKLE-LICENSE.txt'
    shutil.copy2(license_file, resources/license_file.name)
    version = os.environ.get('CLOUDDRIVE_APP_VERSION', '0.5.7')
    build = os.environ.get('CLOUDDRIVE_APP_BUILD', '18')
    if not re.fullmatch(r'\d+\.\d+\.\d+', version) or not re.fullmatch(r'\d+(?:\.\d+){0,2}', build):
        raise RuntimeError('App version/build must contain numeric components.')
    plist = {'CFBundleExecutable': 'CloudDrive', 'CFBundleIdentifier': signing.APP_ID,
             'CFBundleName': 'CloudDrive', 'CFBundleDisplayName': 'CloudDrive',
             'CFBundleIconFile': 'CloudDrive.icns',
             'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': version,
             'CFBundleVersion': build, 'LSMinimumSystemVersion': '14.0',
             'NSHighResolutionCapable': True}
    plist.update(metadata)
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(plist))
    files = sorted([*ROOT.glob('Sources/**/*.swift'), *ROOT.glob('Assets/*.png'), *ROOT.glob('scripts/*.*'),
                    *ROOT.glob('vendor/patches/*.patch'), ROOT/'vendor/RCLONE_BUILD.json',
                    ROOT/'release-config.json', ROOT/'Package.resolved', ROOT/'Package.swift', *ROOT.glob('CloudDrive.xcodeproj/project.pbxproj')])
    source_commit = os.environ.get('CLOUDDRIVE_SOURCE_COMMIT')
    if source_commit is not None and not re.fullmatch(r'[a-f0-9]{40}', source_commit):
        raise RuntimeError('Source commit must be a full Git SHA.')
    info = {'version': version, 'build': build, 'sourceCommit': source_commit,
            'builtAtUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'sources': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files},
            'rcloneSHA256': hashlib.sha256((resources/'rclone').read_bytes()).hexdigest()}
    (resources/'BuildInfo.json').write_text(json.dumps(info, indent=2)+'\n')
    signing.sign(app)
    print(app)


def main():
    try:
        if len(sys.argv) == 3 and sys.argv[1] == '--preflight':
            check_inactive(pathlib.Path(sys.argv[2]).resolve())
            signing.selection()
        elif len(sys.argv) == 4:
            package(*(pathlib.Path(arg).resolve() for arg in sys.argv[1:]))
        else:
            raise RuntimeError('Usage: package-app.py APP PRODUCTS BACKEND, or --preflight APP')
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
