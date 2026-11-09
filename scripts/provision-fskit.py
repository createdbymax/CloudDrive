#!/usr/bin/env python3
"""Provision only CloudDriveFS using the existing Xcode account and stable signer.

Default is a local plan. --apply lets Xcode contact Apple for the selected team's
existing bundle identifier. It never purchases membership, installs the app,
activates extensions, changes keychain ACLs, or updates the app's pinned signer.
"""
import argparse
import hashlib
import json
import os
import pathlib
import plistlib
import re
import subprocess
import sys
import uuid

import fskit_packaging
import signing

ROOT = pathlib.Path(__file__).resolve().parents[1]


def build_command(team, output, register_device=False):
    if not re.fullmatch(r'[A-Z0-9]{10}', team): raise ValueError('Use the existing ten-character development team ID.')
    command = ['/usr/bin/xcodebuild', '-project', str(ROOT/'CloudDrive.xcodeproj'), '-target', 'CloudDriveFS',
               '-configuration', 'Debug', 'SYMROOT='+str(output/'Products'), 'OBJROOT='+str(output/'Intermediates'),
               'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGNING_REQUIRED=YES', 'CODE_SIGN_STYLE=Automatic',
               'DEVELOPMENT_TEAM='+team, 'CODE_SIGN_IDENTITY=Apple Development', 'PROVISIONING_PROFILE_SPECIFIER=',
               '-allowProvisioningUpdates']
    if register_device: command.append('-allowProvisioningDeviceRegistration')
    return command+['build']


def failure_code(log):
    if 'No Accounts:' in log: return 'xcode-account-sign-in-required'
    if 'conflicting provisioning settings' in log: return 'conflicting-signing-settings'
    if 'doesn\'t support' in log or 'does not support' in log: return 'capability-or-team-not-supported'
    if 'not registered' in log or 'no devices' in log.lower(): return 'development-device-registration-required'
    if 'No profiles for' in log: return 'matching-profile-unavailable'
    return 'build-or-provisioning-failed'


def validate_generated_profile(profile, team, certificate_sha1):
    if fskit_packaging.validate_profile_dictionary(profile) != team:
        raise RuntimeError('Generated profile belongs to a different team.')
    certificates = {hashlib.sha1(value).hexdigest().upper() for value in profile.get('DeveloperCertificates', []) if isinstance(value, bytes)}
    if certificate_sha1.upper() not in certificates:
        raise RuntimeError('Generated profile does not authorize the existing pinned signing certificate. The app signer was not changed.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--team', required=True, help='Existing team; this tool never chooses a different team.')
    parser.add_argument('--output', type=pathlib.Path, default=ROOT/'build/fskit-provisioning')
    parser.add_argument('--apply', action='store_true', help='Allow Xcode to contact Apple to provision and build this extension.')
    parser.add_argument('--register-device', action='store_true', help='Also let Xcode register this development Mac if necessary.')
    args = parser.parse_args()
    output = args.output.resolve()
    command = build_command(args.team, output, args.register_device)
    identity = signing.selection()
    if identity == '-': raise RuntimeError('FSKit provisioning requires the existing Apple signing certificate.')
    baseline = signing.BASELINE.read_bytes() if signing.BASELINE.exists() else None
    report = {'schema': 1, 'status': 'plan', 'bundleID': fskit_packaging.EXTENSION_ID,
              'team': args.team, 'command': command, 'changes': 'Xcode-managed development provisioning only; app signer remains pinned.',
              'activation': 'not-attempted'}
    if not args.apply:
        print(json.dumps(report, indent=2)); return 0
    output.mkdir(parents=True, exist_ok=True)
    log = output/('provision-'+uuid.uuid4().hex+'.log')
    fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        result = subprocess.run(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
    if baseline is not None and signing.BASELINE.read_bytes() != baseline:
        raise RuntimeError('Pinned signing metadata changed during provisioning; review before packaging.')
    report['log'] = str(log)
    if result.returncode:
        report['status'] = failure_code(log.read_text(errors='replace'))
        print(json.dumps(report, indent=2)); return 2
    extension = output/'Products/Debug/CloudDriveFS.appex'
    profile_path = extension/'Contents/embedded.provisionprofile'
    decoded = subprocess.run(['/usr/bin/security', 'cms', '-D', '-i', str(profile_path)], capture_output=True, check=True)
    profile = plistlib.loads(decoded.stdout)
    validate_generated_profile(profile, args.team, identity)
    fskit_packaging.validate_extension_info(plistlib.loads((extension/'Contents/Info.plist').read_bytes()))
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(extension)], check=True, capture_output=True)
    signed = subprocess.run(['/usr/bin/codesign', '--display', '--entitlements', ':-', str(extension)], check=True, capture_output=True)
    entitlements = plistlib.loads(signed.stdout)
    if (entitlements.get('com.apple.security.application-groups') != [args.team+'.cd'] or
            entitlements.get('com.apple.developer.team-identifier') != args.team):
        raise RuntimeError('Provisioned extension does not carry the required same-team app group.')
    report.update(status='ready-for-packaging', profile=str(profile_path), extension=str(extension),
                  profileSHA256=hashlib.sha256(profile_path.read_bytes()).hexdigest())
    print(json.dumps(report, indent=2)); return 0


if __name__ == '__main__':
    try: sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print('FSKit provisioning stopped: '+str(error), file=sys.stderr); sys.exit(2)
