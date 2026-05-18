#!/usr/bin/env bash
set -euo pipefail
tmp=/var/tmp/akita-manifest-revisions
rm -rf "$tmp"
git clone --depth=1 --branch=android-gs-akita-6.1-android16 https://android.googlesource.com/kernel/manifest "$tmp" >/dev/null 2>&1

echo '--- projects with revision overrides ---'
grep -E '<project ' "$tmp/default.xml" | grep -E 'revision=' | head -40
echo
echo '--- projects WITHOUT a revision attribute (use default) ---'
grep -E '<project ' "$tmp/default.xml" | grep -v 'revision=' | head -40
echo
echo '--- summary ---'
total=$(grep -c '<project ' "$tmp/default.xml")
with_rev=$(grep -E '<project ' "$tmp/default.xml" | grep -cE 'revision=' || true)
without_rev=$(( total - with_rev ))
echo "total=$total with_revision=$with_rev without_revision=$without_rev"
