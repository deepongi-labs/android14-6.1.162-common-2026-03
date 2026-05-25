#!/bin/bash
set -e
fetch_patch_or_fail() {
  local url="$1"
  local destination="$2"
  curl --fail --location --silent --show-error "$url" -o "$destination"
}

apply_patch_or_fail() {
  local patch_file="$1"
  local description="$2"

  if patch -p1 --forward --dry-run < "$patch_file" >/dev/null 2>&1; then
    patch -p1 --forward < "$patch_file"
  elif patch -p1 --reverse --dry-run < "$patch_file" >/dev/null 2>&1; then
    echo "ℹ️ ${description} already present, skipping."
  elif git apply --3way --check "$patch_file" >/dev/null 2>&1; then
    echo "📋 Applying patch with 3-way merge: $description"
    git apply --3way "$patch_file"
  else
    echo "❌ ${description} could not be applied cleanly: $patch_file"
    exit 1
  fi
}

apply_repo_patch_or_fail() {
  local patch_file="$1"
  local description="$2"
  apply_patch_or_fail "$GITHUB_WORKSPACE/$patch_file" "$description"
}

apply_remote_patch_with_policy() {
  local url="$1"
  local local_name="$2"
  local description="$3"

  local destination="/tmp/${local_name}"
  if ! curl --fail --location --silent --show-error "$url" -o "$destination"; then
    if [ "${KERNELTOAST_PATCH_POLICY}" = "strict" ]; then
      echo "❌ ${description} download failed in strict mode: ${url}"
      exit 1
    fi
    echo "⚠️  Skipping ${description}: failed to download ${url}"
    return 0
  fi
  if [ ! -s "$destination" ]; then
    if [ "${KERNELTOAST_PATCH_POLICY}" = "strict" ]; then
      echo "❌ ${description} downloaded empty patch in strict mode: ${url}"
      exit 1
    fi
    echo "⚠️  Skipping ${description}: downloaded empty patch from ${url}"
    return 0
  fi

  if [ "${KERNELTOAST_PATCH_POLICY}" = "strict" ]; then
    if git apply --check "$destination" >/dev/null 2>&1; then
      git apply "$destination"
      echo "✅ Applied ${description}"
      printf '%s | %s | applied-strict\n' "$description" "$url" >> "${PATCH_MANIFEST:-/dev/null}"
      return 0
    fi
    if git apply --reverse --check "$destination" >/dev/null 2>&1; then
      echo "ℹ️ ${description} already present, skipping."
      printf '%s | %s | already-present-strict\n' "$description" "$url" >> "${PATCH_MANIFEST:-/dev/null}"
      return 0
    fi
    echo "❌ ${description} failed strict git apply check: ${url}"
    echo "::group::${description} strict apply diagnostics"
    git apply --check --verbose "$destination" || true
    echo "::endgroup::"
    exit 1
  fi

  if patch -p1 --forward --dry-run < "$destination" >/dev/null 2>&1; then
    patch -p1 --forward < "$destination"
    echo "✅ Applied ${description}"
    printf '%s | %s | applied\n' "$description" "$url" >> "${PATCH_MANIFEST:-/dev/null}"
  elif patch -p1 --reverse --dry-run < "$destination" >/dev/null 2>&1; then
    echo "ℹ️ ${description} already present, skipping."
    printf '%s | %s | already-present\n' "$description" "$url" >> "${PATCH_MANIFEST:-/dev/null}"
  elif git apply --3way --check "$destination" >/dev/null 2>&1; then
    echo "📋 Applying patch with 3-way merge: $description"
    git apply --3way "$destination"
    echo "✅ Applied ${description} via 3-way merge"
    printf '%s | %s | applied-3way\n' "$description" "$url" >> "${PATCH_MANIFEST:-/dev/null}"
  else
    if [ "${KERNELTOAST_PATCH_POLICY}" = "strict" ]; then
      echo "❌ ${description} failed to apply cleanly in strict mode"
      exit 1
    fi
    echo "⚠️  Skipping ${description}: patch drift against current kernel ref"
    printf '%s | %s | skipped-stale\n' "$description" "$url" >> "${PATCH_MANIFEST:-/dev/null}"
  fi
}

cd kernel

# 0. GKI ABI symbol checks: keep stripped on akita.
# Background: removing android/abi_gki_protected_exports_* lets the
# kernel add new EXPORT_SYMBOLs without ABI-hash check failures.
# On Pixel 8 (akita) Wi-Fi (BCM4389) the vendor module needs symbols
# that aren't in the protected list, so leaving the file in place
# blocks Wi-Fi module load. We strip by default; opt out by setting
# KEEP_PROTECTED_EXPORTS=true if/when the underlying symbol is
# added to the GKI protected ABI properly.
if [ "${KEEP_PROTECTED_EXPORTS:-false}" = "true" ]; then
  echo "🔒 Keeping android/abi_gki_protected_exports_* (KEEP_PROTECTED_EXPORTS=true)"
else
  echo "🚫 Removing GKI protected exports (akita Wi-Fi BCM4389 workaround)..."
  rm -f android/abi_gki_protected_exports_* || true
fi

# 1. CLIDR uninitialized fix (use local copy, not a remote SHA-pinned URL)
apply_repo_patch_or_fail ".github/patches/fix-clidr-uninitialized.patch" "CLIDR initialization fix"

# 2. (Optional) Wi-Fi patch from OnePlus 12 (Qualcomm SM8650 tree)
# Tensor G3 (Pixel 8, akita) uses Broadcom BCM4389 Wi-Fi, NOT QCA.
# The 3-way fallback in apply_patch_or_fail can land hunks in the wrong
# place on a foreign WLAN driver, panicking on first wpa_supplicant up.
# Disabled by default; opt in with apply_oneplus12_wifi_patch=true.
if [ "${APPLY_ONEPLUS12_WIFI_PATCH:-false}" = "true" ]; then
  echo "📶 Applying OnePlus 12 (SM8650) Wi-Fi patch (opt-in)..."
  fetch_patch_or_fail "${WIFI_PATCH_URL}" /tmp/wifi-fix.patch
  if [ -s /tmp/wifi-fix.patch ]; then echo "✅ Wi-Fi patch downloaded"; else echo "❌ Wi-Fi patch missing"; exit 1; fi
  apply_patch_or_fail /tmp/wifi-fix.patch "Wi-Fi fix"
else
  echo "⏭️  OnePlus 12 (SM8650) Wi-Fi patch skipped: incompatible with Pixel 8 (BCM4389)"
fi

# 2b. Apply selected kerneltoast 16.0.0-sultan optimizations.
if [ "${KERNELTOAST_PATCH_POLICY}" != "off" ]; then
  echo "🚀 Applying selected kerneltoast scheduler/power commits (${KERNELTOAST_PATCH_POLICY})..."
  KERNELTOAST_APPLIED_COUNT=0
  apply_remote_patch_with_policy "${KT_PATCH_ARCH_TOPOLOGY_MIN_FREQ_SCALE_URL}" "kt-arch-topology-min-freq-scale.patch" "kerneltoast: arch_topology minimum frequency scale"
  KERNELTOAST_APPLIED_COUNT=$((KERNELTOAST_APPLIED_COUNT + 1))
  apply_remote_patch_with_policy "${KT_PATCH_SCHED_CASS_UCLAMP_PACKING_URL}" "kt-sched-cass-uclamp-packing.patch" "kerneltoast: sched/cass uclamp packing threshold"
  KERNELTOAST_APPLIED_COUNT=$((KERNELTOAST_APPLIED_COUNT + 1))
  apply_remote_patch_with_policy "${KT_PATCH_SCHEDUTIL_IGNORE_FIE_RATELIMIT_URL}" "kt-schedutil-ignore-fie-ratelimit.patch" "kerneltoast: schedutil ignore FIE rate-limit on scale-up"
  KERNELTOAST_APPLIED_COUNT=$((KERNELTOAST_APPLIED_COUNT + 1))
  apply_remote_patch_with_policy "${KT_PATCH_SCHEDUTIL_DEFAULT_RATELIMIT_URL}" "kt-schedutil-default-ratelimit.patch" "kerneltoast: schedutil default rate-limit 2000us"
  KERNELTOAST_APPLIED_COUNT=$((KERNELTOAST_APPLIED_COUNT + 1))
  if [ "${KERNELTOAST_PATCH_POLICY}" = "strict" ] && [ "$KERNELTOAST_APPLIED_COUNT" -ne 4 ]; then
    echo "❌ Strict kerneltoast expected 4 commits, processed ${KERNELTOAST_APPLIED_COUNT}"
    exit 1
  fi
  echo "✅ Kerneltoast patchset processed ${KERNELTOAST_APPLIED_COUNT}/4 commits (${KERNELTOAST_PATCH_POLICY})"
else
  echo "⏭️  kerneltoast patchset disabled by policy"
fi

# 3. Fix KernelSU stack overflow in variant trees that still carry this implementation.
if [ -f "drivers/kernelsu/app_profile.c" ] && grep -q "char comm\\[TASK_COMM_LEN\\];" drivers/kernelsu/app_profile.c; then
  python -c 'from pathlib import Path; p=Path("drivers/kernelsu/app_profile.c"); t=p.read_text(); p.write_text(t.replace("char comm[TASK_COMM_LEN];", "static char comm[TASK_COMM_LEN];", 1))'
  echo "✅ app_profile stack workaround applied"
else
  echo "⏭️  app_profile stack workaround not needed"
fi

# 4. Fix localversion script appending dirty flags
apply_repo_patch_or_fail ".github/patches/global/fix_setlocalversion_dirty.patch" "setlocalversion dirty suffix fix"

if [ "${DIRTY_MODULE_ABI_BYPASS}" = "true" ]; then
  echo "⚠️  Applying dirty vendor module ABI bypass"
  apply_repo_patch_or_fail ".github/patches/global/dirty_allow_vendor_module_crcs.patch" "dirty vendor module CRC bypass"
  apply_repo_patch_or_fail ".github/patches/global/dirty_allow_vendor_module_vermagic.patch" "dirty vendor module vermagic bypass"
fi

# 5. Fix libbpf compilation error
echo "🔧 Patching libbpf.c type casting..."
apply_repo_patch_or_fail ".github/patches/global/fix_libbpf_strchr_cast.patch" "libbpf strchr cast fix"

if [ "${GOVERNOR_MODE}" = "dynasched" ]; then
  echo "🔧 Installing dynasched cluster-aware governor..."
  cp "$GITHUB_WORKSPACE/.github/patches/global/cpufreq_dynasched.c" \
     kernel/sched/cpufreq_dynasched.c
  # Check if patch is already applied using reverse dry-run (most reliable for dirty builds)
  if patch -p1 --reverse --dry-run < "$GITHUB_WORKSPACE/.github/patches/global/add_dynasched_governor.patch" >/dev/null 2>&1; then
    echo "ℹ️ dynasched governor patch already applied, skipping."
    printf 'dynasched governor | kernel/sched/build_utility.c+drivers/cpufreq/Kconfig | already-present\n' >> "${PATCH_MANIFEST:-/dev/null}"
  else
    apply_repo_patch_or_fail ".github/patches/global/add_dynasched_governor.patch" "dynasched governor"
    printf 'dynasched governor | kernel/sched/build_utility.c+drivers/cpufreq/Kconfig | applied\n' >> "${PATCH_MANIFEST:-/dev/null}"
  fi

  if ! grep -q '^CONFIG_CPU_FREQ_GOV_DYNASCHED=y$' arch/arm64/configs/gki_defconfig 2>/dev/null; then
    echo "CONFIG_CPU_FREQ_GOV_DYNASCHED=y" >> arch/arm64/configs/gki_defconfig
  fi
  python3 - <<'PY'
from pathlib import Path

path = Path('drivers/cpufreq/Kconfig')
text = path.read_text()
if 'CPU_FREQ_DEFAULT_GOV_DYNASCHED' not in text:
    text = text.replace(
        'default CPU_FREQ_DEFAULT_GOV_USERSPACE if ARM_SA1100_CPUFREQ || ARM_SA1110_CPUFREQ\n',
        'default CPU_FREQ_DEFAULT_GOV_USERSPACE if ARM_SA1100_CPUFREQ || ARM_SA1110_CPUFREQ\n\tdefault CPU_FREQ_DEFAULT_GOV_DYNASCHED if ARM64\n',
        1,
    )
    text = text.replace(
        'endchoice\n\nconfig CPU_FREQ_GOV_PERFORMANCE',
        'config CPU_FREQ_DEFAULT_GOV_DYNASCHED\n\tbool "dynasched"\n\tdepends on SMP\n\thelp\n\t  Use the dynasched Tensor G3 cluster-aware CPUFreq governor by default.\n\nendchoice\n\nconfig CPU_FREQ_GOV_PERFORMANCE',
        1,
    )
path.write_text(text)
PY
  sed -i '/^CONFIG_CPU_FREQ_DEFAULT_GOV_/d' arch/arm64/configs/gki_defconfig
  echo "CONFIG_CPU_FREQ_DEFAULT_GOV_DYNASCHED=y" >> arch/arm64/configs/gki_defconfig
  printf 'dynasched governor source | kernel/sched/cpufreq_dynasched.c | applied\n' >> "${PATCH_MANIFEST:-/dev/null}"
else
  echo "⏭️  dynasched governor disabled by governor_mode=${GOVERNOR_MODE}"
fi


