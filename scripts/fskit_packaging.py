#!/usr/bin/env python3
"""Explicit, provisioned FSKit embedding. A certificate alone is not a grant."""
import datetime
import hashlib
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile

EXTENSION_ID = 'local.bucketdrive.app.filesystem'


def validate_extension_info(info):
    """Validate the resource contract before signing a filesystem extension."""
    attributes = info.get('EXAppExtensionAttributes', {})
    if (info.get('CFBundleIdentifier') != EXTENSION_ID or
            info.get('CFBundleExecutable') != 'CloudDriveFS' or
            info.get('CFBundlePackageType') != 'XPC!' or
            attributes.get('EXExtensionPointIdentifier') != 'com.apple.fskit.fsmodule' or
            attributes.get('FSSupportsPathURLs') is not True or
            attributes.get('FSRequiresSecurityScopedPathURLResources') is not True or
            attributes.get('FSSupportsBlockResources') is not False or
            attributes.get('FSShortName') != 'clouddrive'):
        raise RuntimeError('The FSKit extension does not declare the expected secured path-resource module.')
    try:
        minimum = tuple(int(part) for part in info['LSMinimumSystemVersion'].split('.'))
    except (KeyError, AttributeError, ValueError):
        raise RuntimeError('The FSKit extension has no valid minimum macOS version.') from None
    if minimum < (26, 0):
        raise RuntimeError('The FSKit path-resource extension requires macOS 26 or later.')


def validate_profile_dictionary(profile, now=None):
    entitlements = profile.get('Entitlements', {})
    if entitlements.get('com.apple.developer.fskit.fsmodule') is not True:
        raise RuntimeError('The selected profile does not authorize the FSKit Module entitlement.')
    teams = profile.get('TeamIdentifier', [])
    if len(teams) != 1 or not isinstance(teams[0], str) or not teams[0]:
        raise RuntimeError('The selected FSKit profile has no unambiguous team identity.')
    application = entitlements.get('com.apple.application-identifier', entitlements.get('application-identifier'))
    if application != teams[0]+'.'+EXTENSION_ID:
        raise RuntimeError('The FSKit profile must explicitly authorize '+EXTENSION_ID+'.')
    expiration = profile.get('ExpirationDate')
    if not isinstance(expiration, datetime.datetime):
        raise RuntimeError('The selected FSKit profile has no expiration date.')
    if expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=datetime.timezone.utc)
    if expiration <= (now or datetime.datetime.now(datetime.timezone.utc)):
        raise RuntimeError('The selected FSKit profile has expired.')
    return teams[0]


def requested_profile(environment):
    if environment.get('CLOUDDRIVE_INCLUDE_FSKIT', '0') not in {'0', '1'}:
        raise RuntimeError('CLOUDDRIVE_INCLUDE_FSKIT must be 0 or 1.')
    if environment.get('CLOUDDRIVE_INCLUDE_FSKIT') != '1':
        return None
    raw = environment.get('CLOUDDRIVE_FSKIT_PROFILE', '')
    if not raw or not pathlib.Path(raw).is_file():
        raise RuntimeError('FSKit activation requires an Apple-issued provisioning profile for '+EXTENSION_ID+
                           ' with the FSKit Module capability. Set CLOUDDRIVE_FSKIT_PROFILE; no unprovisioned extension was embedded.')
    path = pathlib.Path(raw).resolve()
    result = subprocess.run(['/usr/bin/security', 'cms', '-D', '-i', str(path)],
                            capture_output=True, timeout=30)
    if result.returncode:
        raise RuntimeError('The selected FSKit provisioning profile could not be decoded.')
    try:
        profile = plistlib.loads(result.stdout)
    except (ValueError, plistlib.InvalidFileException) as error:
        raise RuntimeError('The selected FSKit provisioning profile is malformed.') from error
    team = validate_profile_dictionary(profile)
    return path, profile, team


def embed_extension(app, products, root, version, build, profile, signing):
    target = app/'Contents/Extensions/CloudDriveFS.appex'
    if profile is None:
        if target.exists():
            shutil.rmtree(target)  # Inactive build output only; never installed user state.
        return None
    source = pathlib.Path(os.environ.get('CLOUDDRIVE_FSKIT_EXTENSION', str(products/'CloudDriveFS.appex'))).resolve()
    if not (source/'Contents/MacOS/CloudDriveFS').is_file():
        raise RuntimeError('Build the CloudDriveFS Xcode target before requesting FSKit packaging.')
    validate_extension_info(plistlib.loads((source/'Contents/Info.plist').read_bytes()))
    identity = signing.selection()
    if identity == '-':
        raise RuntimeError('FSKit packaging requires an authorized certificate/profile; ad-hoc signing is not supported.')
    path, metadata, team = profile
    authorized = {hashlib.sha1(certificate).hexdigest().upper() for certificate in metadata.get("DeveloperCertificates", []) if isinstance(certificate, bytes)}
    if identity.upper() not in authorized:
        raise RuntimeError("The FSKit profile does not authorize the selected signing certificate.")
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(source, target, symlinks=True)
    info_path = target/'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    if info.get('CFBundleIdentifier') != EXTENSION_ID:
        raise RuntimeError('FSKit extension bundle identity does not match the authorized profile.')
    info.update(CFBundleShortVersionString=version, CFBundleVersion=build)
    info_path.write_bytes(plistlib.dumps(info))
    shutil.copy2(path, target/'Contents/embedded.provisionprofile')
    entitlements = plistlib.loads((root/'Sources/CloudDriveFS/CloudDriveFS.entitlements').read_bytes())
    entitlements['com.apple.security.application-groups'] = [team+'.cd']
    entitlement_key = 'com.apple.application-identifier' if 'com.apple.application-identifier' in metadata['Entitlements'] else 'application-identifier'
    entitlements[entitlement_key] = team+'.'+EXTENSION_ID
    entitlements['com.apple.developer.team-identifier'] = team
    with tempfile.TemporaryDirectory(prefix='clouddrive-fskit-sign-') as temporary:
        entitlement_path = pathlib.Path(temporary)/'entitlements.plist'
        entitlement_path.write_bytes(plistlib.dumps(entitlements))
        signing.run(signing.codesign_args(identity)+['--identifier', EXTENSION_ID, '--entitlements', str(entitlement_path), str(target)])
    signing.run(['/usr/bin/codesign', '--verify', '--strict', str(target)])
    details = signing.run(['/usr/bin/codesign', '--display', '--verbose=4', str(target)])
    if 'TeamIdentifier='+team not in details:
        raise RuntimeError('The FSKit signature and provisioning profile use different teams.')
    return target
