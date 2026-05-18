#!/usr/bin/env bash
set -euo pipefail
tmp=/var/tmp/akita-manifest-inspect
rm -rf "$tmp"
git clone --depth=1 --branch=android-gs-akita-6.1-android16 https://android.googlesource.com/kernel/manifest "$tmp" >/dev/null 2>&1

echo '--- repo defaults ---'
grep -E 'default revision|<remote' "$tmp/default.xml"
echo
echo '--- akita-relevant projects ---'
grep -E 'name="kernel/(common|devices/google/(akita|zuma|common))"' "$tmp/default.xml"
echo
echo '--- total project count ---'
grep -c '<project ' "$tmp/default.xml"
echo
echo '--- linker entries from common kernel ---'
sed -n '/name="kernel\/common"/,/<\/project>/p' "$tmp/default.xml"
