#!/usr/bin/env bash
set -euo pipefail
projects=(
  kernel/common
  kernel/build
  kernel/devices/google/akita
  kernel/devices/google/zuma
  kernel/devices/google/common
  kernel/google-modules/gpu
  platform/external/bazel-skylib
  platform/prebuilts/clang/host/linux-x86
  toolchain/prebuilts/ndk/r23
)
branches=(
  android-gs-akita-6.1-android16
  android-gs-akita-6.1-android16-beta
  android-gs-akita-6.1-android15-qpr2
)

for p in "${projects[@]}"; do
  for b in "${branches[@]}"; do
    if git ls-remote "https://android.googlesource.com/$p" "refs/heads/$b" 2>/dev/null | grep -q "$b"; then
      echo "OK   $p :: $b"
    else
      echo "MISS $p :: $b"
    fi
  done
  echo
done
