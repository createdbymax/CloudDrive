#!/usr/bin/env python3
"""Build the real FSKit extension without installing or activating it.

Signing and embedding are performed by package-app.py only after an explicit
FSKit profile passes its capability, identity, certificate and expiration gates.
"""
import argparse
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=pathlib.Path, default=ROOT/'build/fskit-extension')
    parser.add_argument('--configuration', choices=['Debug', 'Release'], default='Release')
    parser.add_argument('--optimize', action='store_true', help='Compile with release optimization even when a Debug diagnostic entry point is needed.')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    subprocess.run([sys.executable, str(ROOT/'scripts/generate-xcode-project.py')], check=True)
    command = ['/usr/bin/xcodebuild', '-project', str(ROOT/'CloudDrive.xcodeproj'), '-target', 'CloudDriveFS',
               '-configuration', args.configuration, 'SYMROOT='+str(output/'Products'),
               'OBJROOT='+str(output/'Intermediates'), 'CODE_SIGNING_ALLOWED=NO', 'build']
    if args.optimize: command.insert(-1, 'SWIFT_OPTIMIZATION_LEVEL=-O')
    log = output/'build.log'
    with log.open('wb') as stream:
        result = subprocess.run(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
    if result.returncode:
        print('FSKit extension build failed; see '+str(log), file=sys.stderr)
        return result.returncode
    extension = output/'Products'/args.configuration/'CloudDriveFS.appex'
    if not (extension/'Contents/MacOS/CloudDriveFS').is_file():
        print('Xcode did not produce the expected extension.', file=sys.stderr)
        return 1
    print(extension)
    print('Unsigned build only. Not installed, activated or qualified for Finder.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
