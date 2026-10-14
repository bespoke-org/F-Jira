#!/usr/bin/env python3
"""Export the rounded app-icon artwork to a macOS asset catalog, iconset, and ICNS."""
import json
import shutil
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = root / 'artwork' / 'F Jira App Icon.png'
iconset = root / 'artwork' / 'F Jira.iconset'
catalog = root / 'fjira' / 'Assets.xcassets'
appicon = catalog / 'AppIcon.appiconset'
iconset.mkdir(parents=True, exist_ok=True)
appicon.mkdir(parents=True, exist_ok=True)
info = {'author': 'xcode', 'version': 1}
(catalog / 'Contents.json').write_text(json.dumps({'info': info}, indent=2) + '\n')
images = []
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        filename = f'icon_{size}x{size}' + ('@2x' if scale == 2 else '') + '.png'
        destination = iconset / filename
        pixels = str(size * scale)
        subprocess.run(['sips', '-z', pixels, pixels, str(source), '--out', str(destination)],
                       check=True, stdout=subprocess.DEVNULL)
        shutil.copyfile(destination, appicon / filename)
        images.append({'filename': filename, 'idiom': 'mac', 'size': f'{size}x{size}', 'scale': f'{scale}x'})
(appicon / 'Contents.json').write_text(json.dumps({'images': images, 'info': info}, indent=2) + '\n')
subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(root / 'artwork' / 'F Jira.icns')], check=True)
print('Generated 10 macOS icon sizes and F Jira.icns')
