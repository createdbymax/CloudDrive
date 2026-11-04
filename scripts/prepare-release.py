#!/usr/bin/env python3
"""Prepare local GitHub Release assets. Never creates a release or uploads anything."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def main():
    config = json.loads((ROOT/'release-config.json').read_text())
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository', default=config['repository'], help='Public GitHub owner/repository')
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True, type=int, help='Strictly increasing CFBundleVersion')
    parser.add_argument('--public-key', default=config['publicKey'], help='Sparkle Ed25519 PUBLIC key')
    parser.add_argument('--account', default=config['keychainAccount'], help='Sparkle signing key Keychain account')
    parser.add_argument('--finalize', action='store_true', help='Create signed assets from the previously staged, notarized and stapled app')
    parser.add_argument('--draft', action='store_true', help='Local development-signed ZIP and unsigned preview feed; not distributable')
    parser.add_argument('--previous-appcast', type=Path, help='Local copy of the last published feed for monotonic build validation')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repository) or args.build <= 0:
        parser.error('Use owner/repository and a positive build number.')
    if not re.fullmatch(r'\d+\.\d+\.\d+', args.version):
        parser.error('Version must be X.Y.Z.')
    if args.previous_appcast:
        builds = [e.text for e in ET.parse(args.previous_appcast).iter('{'+NS+'}version')]
        if any(not b or not b.isdigit() or int(b) >= args.build for b in builds):
            parser.error('Build must exceed all builds in the previous feed (integer builds required).')
    tag = 'v'+args.version
    feed = f'https://github.com/{args.repository}/releases/latest/download/appcast.xml'
    output = ROOT/'build/releases'/f'{tag}-{args.build}'
    if args.draft and args.finalize:
        parser.error('--draft and --finalize cannot be combined.')
    if output.exists() and not args.finalize:
        parser.error('Output already exists; use a new build number or move the previous output aside.')
    env = dict(os.environ, CLOUDDRIVE_APP_VERSION=args.version, CLOUDDRIVE_APP_BUILD=str(args.build),
               CLOUDDRIVE_SPARKLE_FEED_URL=feed, CLOUDDRIVE_SPARKLE_PUBLIC_KEY=args.public_key,
               CLOUDDRIVE_RELEASE='0' if args.draft else '1')
    from sparkle_config import update_metadata
    update_metadata(env)  # Fail before building or creating output.
    app = output/'CloudDrive.app'
    if args.finalize:
        plist = plistlib.loads((app/'Contents/Info.plist').read_bytes())
        expected = {'CFBundleShortVersionString': args.version, 'CFBundleVersion': str(args.build),
                    **update_metadata(env)}
        if any(plist.get(k) != v for k, v in expected.items()):
            parser.error('Staged app metadata does not match release arguments.')
        run('/usr/bin/codesign', '--verify', '--deep', '--strict', app)
    else:
        output.mkdir(parents=True)
        env['CLOUDDRIVE_APP_OUTPUT'] = str(app)
        run(ROOT/'scripts/build-app.sh', env=env)
        if not args.draft:
            print(f'Staged locally: {app}\nNotarize and staple explicitly, then rerun with --finalize. Nothing was submitted or published.')
            return
    archive = output/f'CloudDrive-{args.version}-{args.build}-arm64.zip'
    if archive.exists():
        parser.error('Archive already exists; preserve release immutability by using a new build.')
    backend = Path(os.environ.get('CLOUDDRIVE_BACKEND', str(ROOT/'build/backend/rclone')))
    source_archive = backend.parent/'backend-source.tar.gz'
    notice_manifest = json.loads((app/'Contents/Resources/BackendNotices/MANIFEST.json').read_text())
    if hashlib.sha256(source_archive.read_bytes()).hexdigest() != notice_manifest['sourceArchiveSHA256']:
        parser.error('Corresponding backend source does not match the packaged notices.')
    shutil.copy2(source_archive, output/'backend-source.tar.gz')
    tools = ROOT/'.build/artifacts/sparkle/Sparkle/bin'
    if not args.draft:
        # Notarization submits externally and is deliberately a separate, explicit operation.
        # Accept only an already stapled app; see docs/SPARKLE_RELEASES.md.
        run('/usr/bin/xcrun', 'stapler', 'validate', app)
        run('/usr/sbin/spctl', '--assess', '--type', 'execute', app)
        run('/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, archive)
        signature = run(tools/'sign_update', '--account', args.account, '-p', archive,
                        capture_output=True, text=True).stdout.strip()
        if len(base64.b64decode(signature, validate=True)) != 64:
            raise ValueError('Sparkle did not return a valid archive signature.')
        # Verify the signature against the public key actually embedded in this app.
        verifier = output/'verify.swift'
        verifier.write_text('import Foundation\nimport CryptoKit\nlet a=CommandLine.arguments\nlet key=try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded:a[1])!)\nlet data=try Data(contentsOf:URL(fileURLWithPath:a[3]))\nguard key.isValidSignature(Data(base64Encoded:a[2])!, for:data) else { exit(1) }\n')
        run('/usr/bin/swift', verifier, args.public_key, signature, archive)
        verifier.unlink()
    else:
        run('/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, archive)
        signature = None
    ET.register_namespace('sparkle', NS)
    rss = ET.Element('rss', version='2.0')
    channel = ET.SubElement(rss, 'channel')
    ET.SubElement(channel, 'title').text = 'CloudDrive Updates'
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = f'CloudDrive {args.version}'
    ET.SubElement(item, '{'+NS+'}version').text = str(args.build)
    ET.SubElement(item, '{'+NS+'}shortVersionString').text = args.version
    ET.SubElement(item, '{'+NS+'}minimumSystemVersion').text = '14.0'
    attrs = dict(url=f'https://github.com/{args.repository}/releases/download/{tag}/{archive.name}',
                 length=str(archive.stat().st_size), type='application/octet-stream')
    if signature: attrs['{'+NS+'}edSignature'] = signature
    ET.SubElement(item, 'enclosure', attrs)
    ET.indent(rss)
    feed_file = output/('appcast.preview.xml' if args.draft else 'appcast.xml')
    ET.ElementTree(rss).write(feed_file, encoding='utf-8', xml_declaration=True)
    (output/'SHA256SUMS').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n' for p in [archive, output/'backend-source.tar.gz']))
    (output/'PREPARATION.json').write_text(json.dumps({'draft': args.draft, 'repository': args.repository,
        'tag': tag, 'build': args.build, 'published': False}, indent=2)+'\n')
    print(f'Local assets only: {output}')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f'Release preparation stopped: {error}', file=sys.stderr)
        sys.exit(1)
