#!/usr/bin/env python3
"""Build a disposable synthetic UI preview from the isolated Swift test objects."""
import pathlib, plistlib, subprocess
root = pathlib.Path(__file__).resolve().parents[2]
scratch = root / 'build/SpotlightVerification'
products = scratch / 'out/Products/Debug'
objects = next((scratch/'out/Intermediates.noindex/CloudDrive.build/Debug').glob('*testable-t.build/Objects-normal/arm64'))
app = root/'build/CloudDrive-Spotlight-Preview.app'
macos = app/'Contents/MacOS'; macos.mkdir(parents=True, exist_ok=True)
info = {'CFBundleExecutable':'SpotlightPreview','CFBundleIdentifier':'local.clouddrive.spotlight-preview','CFBundleName':'CloudDrive Spotlight Preview','CFBundlePackageType':'APPL','NSHighResolutionCapable':True,'LSMinimumSystemVersion':'14.0'}
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
subprocess.run(['swiftc','-parse-as-library','-g','-I',str(products),'-F',str(products),'-framework','Sparkle','-Xlinker','-rpath','-Xlinker',str(products), str(root/'experiments/spotlight-preview/main.swift'),*[str(p) for p in objects.glob('*.o') if p.name != 'App.o'],'-o',str(macos/'SpotlightPreview')],check=True)
print(app)
