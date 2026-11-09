#!/usr/bin/env python3
"""Inspect an inactive packaged app's FSKit prerequisites. Never installs or activates it."""
import argparse
import hashlib
import json
import pathlib
import platform
import plistlib
import subprocess
import sys

import fskit_packaging


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024*1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def command(arguments):
    result = subprocess.run(arguments, capture_output=True, timeout=30)
    if result.returncode:
        # Do not export potentially identifying codesign/profile diagnostics.
        raise RuntimeError('Inspection command failed: '+pathlib.Path(arguments[0]).name)
    return result.stdout + result.stderr if '--verbose=4' in arguments else result.stdout


def inspect(app, run=command, os_version=None):
    checks, identities = [], {}
    def check(name, operation):
        try:
            operation()
            checks.append({'check': name, 'status': 'pass'})
        except (OSError, ValueError, RuntimeError, KeyError, TypeError, AttributeError, subprocess.SubprocessError, plistlib.InvalidFileException):
            checks.append({'check': name, 'status': 'blocked'})
    def require(condition):
        if not condition: raise RuntimeError('Prerequisite missing')
    version = os_version if os_version is not None else platform.mac_ver()[0]
    check('macOS-26-or-newer', lambda: require(int(version.split('.')[0]) >= 26))
    extension = app/'Contents/Extensions/CloudDriveFS.appex'
    executable = extension/'Contents/MacOS/CloudDriveFS'
    owner = app/'Contents/Resources/CloudDriveEngine'
    build_path = app/'Contents/Resources/BuildInfo.json'
    check('filesystem-module-resource-contract', lambda: fskit_packaging.validate_extension_info(
        plistlib.loads((extension/'Contents/Info.plist').read_bytes())))
    def digests():
        build = json.loads(build_path.read_text())
        identities.update(engineSHA256=sha256(owner), extensionSHA256=sha256(executable), buildInfoSHA256=sha256(build_path))
        require(build['engineSHA256'] == identities['engineSHA256'])
        require(build['filesystemExtension']['bundleID'] == fskit_packaging.EXTENSION_ID)
        require(build['filesystemExtension']['executableSHA256'] == identities['extensionSHA256'])
    check('packaged-binary-digests', digests)
    for label, path in [('app', app), ('owner', owner), ('extension', extension)]:
        check(label+'-signature', lambda path=path: run(['/usr/bin/codesign', '--verify', '--strict', str(path)]))
    def profile_and_entitlements():
        raw = run(['/usr/bin/security', 'cms', '-D', '-i', str(extension/'Contents/embedded.provisionprofile')])
        profile = plistlib.loads(raw)
        team = fskit_packaging.validate_profile_dictionary(profile)
        entitlements = plistlib.loads(run(['/usr/bin/codesign', '--display', '--entitlements', ':-', str(extension)]))
        require(entitlements.get('com.apple.developer.fskit.fsmodule') is True)
        require(entitlements.get('com.apple.security.app-sandbox') is True)
        require(entitlements.get('com.apple.developer.team-identifier') == team)
        require(entitlements.get('com.apple.security.application-groups') == [team+'.cd'])
        require(entitlements.get('com.apple.application-identifier', entitlements.get('application-identifier')) == team+'.'+fskit_packaging.EXTENSION_ID)
        for member in [app, owner]:
            member_entitlements = plistlib.loads(run(['/usr/bin/codesign', '--display', '--entitlements', ':-', str(member)]))
            require(member_entitlements.get('com.apple.security.application-groups') == [team+'.cd'])
            details = run(['/usr/bin/codesign', '--display', '--verbose=4', str(member)]).decode()
            require('TeamIdentifier='+team in details)
            require('com.apple.developer.team-identifier' not in member_entitlements)
        identities['profileSHA256'] = sha256(extension/'Contents/embedded.provisionprofile')
    check('embedded-profile-and-signed-entitlements', profile_and_entitlements)
    return {'schema': 1, 'scope': 'Read-only packaging prerequisites; not activation or Finder qualification.',
            'status': 'ready-for-activation-test' if all(c['status'] == 'pass' for c in checks) else 'blocked',
            'checks': checks, 'identities': identities,
            'unverified': ['Apple activation/approval', 'mounted Finder callbacks', 'live R2 semantics', 'notarization',
                           'profile certificate matches signed leaf (enforced when package-app.py embeds the extension)']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=pathlib.Path)
    args = parser.parse_args()
    report = inspect(args.app.resolve())
    print(json.dumps(report, indent=2))
    return 0 if report['status'] == 'ready-for-activation-test' else 2


if __name__ == '__main__': sys.exit(main())
