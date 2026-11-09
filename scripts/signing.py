#!/usr/bin/env python3
"""Stable code-signing selection. Never changes Keychain ACLs or creates certificates."""
import hashlib, json, os, pathlib, re, subprocess, sys, plistlib, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP_ID = 'local.bucketdrive.app'
BASELINE = ROOT/'build/signing/stable-identity.json'
SETUP = 'Open Xcode > Settings > Accounts > your team > Manage Certificates > + > Apple Development. Then set CLOUDDRIVE_SIGN_IDENTITY to that certificate fingerprint.'

class SigningError(RuntimeError): pass

def parse_identities(output):
    # Keychain search lists can expose the same certificate identity repeatedly.
    # A fingerprint identifies the certificate; duplicate rows are not distinct signers.
    identities = {}
    for m in re.finditer(r'^\s*\d+\)\s+([A-Fa-f0-9]{40})\s+"([^"]+)"\s*$', output, re.MULTILINE):
        identities.setdefault(m.group(1).upper(), m.group(2))
    return list(identities.items())

def select_identity(identities, requested=None, allow_adhoc=False, baseline=None):
    if requested:
        # Require an exact public certificate fingerprint; do not select an ambiguous name.
        if not re.fullmatch(r'[A-Fa-f0-9]{40}', requested): raise SigningError('CLOUDDRIVE_SIGN_IDENTITY must be a full 40-character certificate fingerprint.')
        matches = [item for item in identities if item[0] == requested.upper()]
        if len(matches) != 1: raise SigningError('The configured signing certificate/private key is not available. '+SETUP)
        return matches[0][0]
    if baseline:
        matches = [item for item in identities if item[0] == baseline.get('certificateSHA1')]
        if len(matches) == 1: return matches[0][0]
        raise SigningError('The pinned signing identity is unavailable. Select an available certificate explicitly to review a renewal; no ad-hoc fallback was made.')
    apple = [item for item in identities if item[1].startswith(('Apple Development:', 'Developer ID Application:', 'Mac Developer:'))]
    if len(apple) == 1: return apple[0][0]
    if len(apple) > 1: raise SigningError('Multiple signing identities are available. Pin one with CLOUDDRIVE_SIGN_IDENTITY; do not change signer between updates.')
    if allow_adhoc: return '-'
    raise SigningError('No stable signing identity is available. '+SETUP+' Ad-hoc preview builds require CLOUDDRIVE_ALLOW_ADHOC=1 and may prompt again after every code change.')

def run(args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=30)
    if result.returncode: raise SigningError('Code-signing check failed. No certificate or Keychain permissions were changed.')
    return result.stdout + result.stderr

def selection():
    # UI-only preview is explicit and never queries Keychain or a signing identity.
    # The application still refuses credential persistence without a certificate.
    if os.environ.get('CLOUDDRIVE_ADHOC_ONLY') == '1':
        return '-'
    baseline = json.loads(BASELINE.read_text()) if BASELINE.exists() else None
    identities = parse_identities(run(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning']))
    if not identities and os.environ.get('CLOUDDRIVE_ALLOW_ADHOC') != '1':
        matching = parse_identities(run(['/usr/bin/security', 'find-identity', '-p', 'codesigning']))
        if matching:
            raise SigningError('Signing certificates and private keys are present, but macOS reports no valid code-signing identity. Check the certificate chain and validity in Keychain Access; creating more leaf certificates will not repair a missing intermediate. See docs/KEYCHAIN_SIGNING_SETUP.md. No ad-hoc fallback was made.')
    return select_identity(identities, os.environ.get('CLOUDDRIVE_SIGN_IDENTITY'), os.environ.get('CLOUDDRIVE_ALLOW_ADHOC') == '1', baseline)

def designated_requirement(output):
    for line in output.splitlines():
        line = line.strip()
        if line.startswith('# '): line = line[2:]
        if line.startswith('designated => '): return line[len('designated => '):]
    raise SigningError('No designated requirement was found.')

def validate_stable_requirement(requirement):
    # A stable signer must not be replaced with a weak identifier-only requirement.
    if 'cdhash' in requirement or ('anchor ' not in requirement and 'certificate ' not in requirement):
        raise SigningError('Signing identity is tied to this code version or lacks a certificate anchor. A stable certificate signature is required.')
    if 'identifier "'+APP_ID+'"' not in requirement: raise SigningError('Application signing identifier changed.')

def codesign_args(identity):
    return ['/usr/bin/codesign', '--force', '--sign', identity] + (
        ['--options', 'runtime', '--timestamp'] if os.environ.get('CLOUDDRIVE_RELEASE') == '1'
        else ['--timestamp=none'])


def app_group_entitlements(team):
    if not re.fullmatch(r'[A-Z0-9]{10}', team):
        raise SigningError('App group requires an exact developer team identifier.')
    # macOS team-prefixed groups are authorized by the signing team; no Keychain
    # access-group entitlement or broad sandbox exception is added. Do not add
    # developer.team-identifier: that restricted entitlement requires a profile
    # on standalone host/engine binaries. TeamIdentifier comes from the signature.
    return {'com.apple.security.application-groups': [team+'.cd']}


def sign_target(target, identifier, identity, app_group_team=None):
    args = codesign_args(identity) + ['--identifier', identifier]
    if app_group_team is None:
        run(args + [str(target)])
        return
    if identity == '-':
        raise SigningError('App group access requires the stable team certificate.')
    with tempfile.TemporaryDirectory(prefix='clouddrive-group-sign-') as temporary:
        path = pathlib.Path(temporary)/'entitlements.plist'
        path.write_bytes(plistlib.dumps(app_group_entitlements(app_group_team)))
        run(args + ['--entitlements', str(path), str(target)])
    details = run(['/usr/bin/codesign', '--display', '--verbose=4', str(target)])
    if 'TeamIdentifier='+app_group_team not in details:
        raise SigningError('App group and signing certificate teams do not match.')


def sign(app, app_group_team=None):
    identity = selection()
    if os.environ.get('CLOUDDRIVE_RELEASE') == '1':
        identities = dict(parse_identities(run(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'])))
        if not identities.get(identity, '').startswith('Developer ID Application:'):
            raise SigningError('Release packaging requires a Developer ID Application identity.')
    framework = app/'Contents/Frameworks/Sparkle.framework'
    if framework.exists():
        version = framework/'Versions/B'
        # Sign nested code first; never use --deep to sign a bundle.
        nested = [version/'Autoupdate', version/'Updater.app',
                  version/'XPCServices/Downloader.xpc', version/'XPCServices/Installer.xpc', framework]
        for target in nested:
            run(codesign_args(identity) + ['--preserve-metadata=identifier,entitlements', str(target)])
    targets = [('Contents/Resources/rclone', APP_ID+'.rclone'), ('Contents/Resources/CloudDriveHelper', APP_ID+'.helper'), ('', APP_ID)]
    for relative, identifier in targets:
        if not relative:
            manifest = app/'Contents/Resources/BuildInfo.json'
            if manifest.exists():
                info = json.loads(manifest.read_text())
                info['rcloneSHA256'] = hashlib.sha256((app/'Contents/Resources/rclone').read_bytes()).hexdigest()
                manifest.write_text(json.dumps(info, indent=2)+'\n')
        target = app/relative if relative else app
        sign_target(target, identifier, identity, app_group_team if not relative else None)
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])
    requirement = designated_requirement(run(['/usr/bin/codesign', '--display', '--requirements', '-', str(app)]))
    signing = {'mode': 'adhoc-preview' if identity == '-' else 'certificate', 'bundleID': APP_ID,
               'certificateSHA1': None if identity == '-' else identity, 'designatedRequirement': None if identity == '-' else requirement}
    if identity != '-':
        validate_stable_requirement(requirement)
        if BASELINE.exists():
            old = json.loads(BASELINE.read_text())
            run(['/usr/bin/codesign', '--verify', '--strict', '--test-requirement', '='+old['designatedRequirement'], str(app)])
        else:
            BASELINE.parent.mkdir(parents=True, exist_ok=True)
            temporary = BASELINE.with_suffix('.tmp')
            temporary.write_text(json.dumps(signing, indent=2)+'\n'); temporary.chmod(0o600); temporary.replace(BASELINE)
    # This is build metadata, not credential data. Re-sign after adding it to the resource seal.
    (app/'Contents/Resources/SigningInfo.json').write_text(json.dumps(signing, indent=2)+'\n')
    sign_target(app, APP_ID, identity, app_group_team)
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])
    final = designated_requirement(run(['/usr/bin/codesign', '--display', '--requirements', '-', str(app)]))
    if identity != '-':
        validate_stable_requirement(final)
        run(['/usr/bin/codesign', '--verify', '--strict', '--test-requirement', '='+requirement, str(app)])
    print('Signed with a stable certificate.' if identity != '-' else 'Ad-hoc PREVIEW ONLY: changed builds can request Keychain approval again.')

def main():
    try:
        if len(sys.argv) == 2 and sys.argv[1] == 'preflight':
            identity = selection()
            print('Signing preflight: stable certificate available.' if identity != '-' else 'Signing preflight: explicit ad-hoc preview; repeated Keychain prompts remain possible.')
        elif len(sys.argv) == 3 and sys.argv[1] == 'sign': sign(pathlib.Path(sys.argv[2]).resolve())
        else: raise SigningError('Use signing.py preflight or signing.py sign APP_PATH')
    except (SigningError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr); return 1
    return 0
if __name__ == '__main__': sys.exit(main())
