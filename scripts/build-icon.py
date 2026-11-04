#!/usr/bin/env python3
"""Build the macOS icon family from the approved CloudDrive artwork."""
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent


def main():
    output = ROOT / 'build/icons/CloudDrive.icns'
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='clouddrive-icon-') as temporary:
        iconset = pathlib.Path(temporary) / 'CloudDrive.iconset'
        iconset.mkdir()
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                pixels = size * scale
                suffix = '@2x' if scale == 2 else ''
                target = iconset / f'icon_{size}x{size}{suffix}.png'
                subprocess.run(['/usr/bin/sips', '-z', str(pixels), str(pixels),
                                str(ROOT / 'Assets/CloudDrive.png'), '--out', str(target)],
                               check=True, stdout=subprocess.DEVNULL)
        subprocess.run(['/usr/bin/iconutil', '-c', 'icns', str(iconset),
                        '-o', str(output)], check=True)
    print(output)


if __name__ == '__main__':
    main()
