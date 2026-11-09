"""Explicit FinderSync embedding; no activation or Finder restart."""
import hashlib
import os
import pathlib
import plistlib
import shutil

EXTENSION_ID = 'local.bucketdrive.app.finder'


def validate_info(info):
    declaration = info.get('NSExtension', {})
    if (info.get('CFBundleIdentifier') != EXTENSION_ID or
            info.get('CFBundleExecutable') != 'CloudDriveFinder' or
            declaration.get('NSExtensionPointIdentifier') != 'com.apple.FinderSync' or
            not declaration.get('NSExtensionPrincipalClass', '').endswith('.FinderSync')):
        raise RuntimeError('Finder extension identity or entry point does not match CloudDrive.')


def embed_extension(app, products, root, version, build, signing):
    include = os.environ.get('CLOUDDRIVE_INCLUDE_FINDER', '0')
    if include not in {'0', '1'}: raise RuntimeError('CLOUDDRIVE_INCLUDE_FINDER must be 0 or 1.')
    destination = app/'Contents/PlugIns/CloudDriveFinder.appex'
    if include == '0':
        if destination.exists(): shutil.rmtree(destination)
        return None
    source = pathlib.Path(os.environ.get('CLOUDDRIVE_FINDER_EXTENSION', str(products/'CloudDriveFinder.appex'))).resolve()
    binary = source/'Contents/MacOS/CloudDriveFinder'
    if not binary.is_file(): raise RuntimeError('Build CloudDriveFinder before requesting Finder actions packaging.')
    info = plistlib.loads((source/'Contents/Info.plist').read_bytes()); validate_info(info)
    if source == destination.resolve(): raise RuntimeError('Finder packaging source must be separate from the inactive app output.')
    if destination.exists(): shutil.rmtree(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, destination, symlinks=True)
    info.update(CFBundleShortVersionString=version, CFBundleVersion=build)
    (destination/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    signing.run(signing.codesign_args(signing.selection()) + ['--identifier', EXTENSION_ID, '--entitlements',
        str(root/'Sources/CloudDriveFinder/CloudDriveFinder.entitlements'), str(destination)])
    signing.run(['/usr/bin/codesign', '--verify', '--strict', str(destination)])
    return {'bundleID': EXTENSION_ID, 'executableSHA256': hashlib.sha256((destination/'Contents/MacOS/CloudDriveFinder').read_bytes()).hexdigest()}
