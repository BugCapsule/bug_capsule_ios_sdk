#!/usr/bin/env python3
"""Verify the complete shipped runtime inventory; never download or modify it."""
import hashlib, json, plistlib
from pathlib import Path
root = Path(__file__).resolve().parents[1]
package = root / 'Packages/BugCapsulePatch'
framework = package / 'Binaries/BcpatchRuntime.xcframework'
manifest = json.loads((package / 'runtime-provenance.json').read_text())
if any(p.is_symlink() for p in framework.rglob('*')):
    raise ValueError('Runtime must not contain symlinks')
actual = {p.relative_to(framework).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
          for p in framework.rglob('*') if p.is_file()}
if actual != manifest['files']:
    raise ValueError('Runtime inventory or hash mismatch')
info = plistlib.loads((framework / 'Info.plist').read_bytes())
slices = {(x['SupportedPlatform'], x.get('SupportedPlatformVariant', ''), tuple(sorted(x['SupportedArchitectures'])))
          for x in info['AvailableLibraries']}
if slices != {('ios', '', ('arm64',)), ('ios', 'simulator', ('arm64', 'x86_64'))}:
    raise ValueError(f'Unexpected runtime slices: {slices}')
print('Verified all bundled runtime files and iOS device/simulator slice declarations.')
