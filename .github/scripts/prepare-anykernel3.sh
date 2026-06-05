#!/bin/bash
set -euo pipefail

AK3_DIR="${1:-AnyKernel3}"

if [ ! -f "${AK3_DIR}/anykernel.sh" ]; then
  echo "::error::${AK3_DIR}/anykernel.sh not found"
  exit 1
fi

python3 - "${AK3_DIR}/anykernel.sh" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()

def set_property(body: str, key: str, value: str) -> str:
    pattern = re.compile(rf'^{re.escape(key)}=.*$', re.MULTILINE)
    replacement = f'{key}={value}'
    if pattern.search(body):
        return pattern.sub(replacement, body, count=1)
    return body.replace("'; } # end properties", f'{replacement}\n\'; }} # end properties', 1)

for key, value in {
    'kernel.string': 'Pixel 8 Series Android 16 GKI Kernel by deepongi @ deepongi-labs',
    'do.devicecheck': '1',
    'do.modules': '0',
    'do.systemless': '1',
    'do.cleanup': '1',
    'do.cleanuponabort': '0',
    'device.name1': 'shiba',
    'device.name2': 'husky',
    'device.name3': 'akita',
    'device.name4': '',
    'device.name5': '',
    # Empty values intentionally allow Android 14/16/17 while device checks
    # protect against flashing on non-Pixel-8-series devices.
    'supported.versions': '',
    'supported.patchlevels': '',
}.items():
    text = set_property(text, key, value)

text = re.sub(r'^block=.*$', 'block=/dev/block/by-name/boot;', text, count=1, flags=re.MULTILINE)
text = re.sub(r'^is_slot_device=.*$', 'is_slot_device=1;', text, count=1, flags=re.MULTILINE)

if 'HEADER_VER=$(grep "HEADER_VER"' in text:
    text = text.replace(
        'HEADER_VER=$(grep "HEADER_VER" /tmp/anykernel/split_img/boot.img-header_version 2>/dev/null || echo "0")',
        'HEADER_VER=$(grep "HEADER_VER" /tmp/anykernel/split_img/boot.img-header_version 2>/dev/null | grep -oE "[0-9]+" | head -1 || echo "0")',
    )

if 'RAMDISK_SIZE=$(grep "RAMDISK_SZ"' in text:
    text = text.replace(
        'RAMDISK_SIZE=$(grep "RAMDISK_SZ" /tmp/anykernel/ramdisk_size 2>/dev/null || echo "0")',
        'RAMDISK_SIZE=$(grep "RAMDISK_SZ" /tmp/anykernel/ramdisk_size 2>/dev/null | grep -oE "[0-9]+" | head -1 || echo "0")',
    )

if 'Pixel 8 series / Android 16 guard' not in text:
    marker = '## AnyKernel boot install\n'
    guard = '''## Pixel 8 series / Android 16 guard
ui_print "Target: Pixel 8 series (shiba/husky/akita)";
ui_print "Android 16 boot images are supported (boot header v4/no boot ramdisk).";

'''
    text = text.replace(marker, marker + guard, 1)

path.write_text(text)
PY

if ! grep -Eiq 'device\.name[0-9]+=shiba' "${AK3_DIR}/anykernel.sh" \
  || ! grep -Eiq 'device\.name[0-9]+=husky' "${AK3_DIR}/anykernel.sh" \
  || ! grep -Eiq 'device\.name[0-9]+=akita' "${AK3_DIR}/anykernel.sh"; then
  echo "::error::AnyKernel3 device assertions must include Pixel 8 (shiba), Pixel 8 Pro (husky), and Pixel 8a (akita)."
  grep -Ein 'device\.name|do\.devicecheck|block=|is_slot_device' "${AK3_DIR}/anykernel.sh" || true
  exit 1
fi

if ! grep -Eq '^block=/dev/block/by-name/boot;' "${AK3_DIR}/anykernel.sh"; then
  echo "::error::AnyKernel3 block target must be /dev/block/by-name/boot for Pixel 8 series GKI packages."
  grep -En '^block=' "${AK3_DIR}/anykernel.sh" || true
  exit 1
fi

echo "✅ AnyKernel3 prepared for Pixel 8 series Android 16 GKI packaging"
