#!/bin/bash
set -euo pipefail
mkdir -p logs
LOG_FILE="$GITHUB_WORKSPACE/logs/build-${KSU_VARIANT}.log"
exec > >(tee -a "$LOG_FILE") 2>&1

summarize_build_failure() {
  if [ ! -f "$LOG_FILE" ]; then
    return 0
  fi

  echo "::group::Build failure summary (${KSU_VARIANT})"
  echo "📄 Last 200 lines of $LOG_FILE"
  tail -n 200 "$LOG_FILE" || true
  echo
  echo "🔎 Matching error signatures"
  grep -nE 'error:|fatal error:|undefined reference|No rule to make target|FAILED:' "$LOG_FILE" | tail -n 80 || echo "No common error signature matched."
  echo "::endgroup::"
}

trap 'status=$?; if [ "$status" -ne 0 ]; then summarize_build_failure; fi; exit "$status"' EXIT

cd kernel
export ARCH=arm64
export PATH="${CLANG_BIN}:/usr/lib/ccache:$PATH"
export CROSS_COMPILE="${ARM64_TOOLCHAIN}"
export CROSS_COMPILE_COMPAT="${ARM32_TOOLCHAIN}"
export CCACHE_DIR="${CCACHE_DIR}"
export CC="ccache ${CLANG_BIN}/clang"
export CXX="ccache ${CLANG_BIN}/clang++"
export HOSTCC="ccache ${CLANG_BIN}/clang"
export HOSTCXX="ccache ${CLANG_BIN}/clang++"
export LD="${CLANG_BIN}/ld.lld"
export HOSTLD="${CLANG_BIN}/ld.lld"
export AR="${CLANG_BIN}/llvm-ar"
export HOSTAR="${CLANG_BIN}/llvm-ar"
export NM="${CLANG_BIN}/llvm-nm"
export OBJCOPY="${CLANG_BIN}/llvm-objcopy"
export OBJDUMP="${CLANG_BIN}/llvm-objdump"
export READELF="${CLANG_BIN}/llvm-readelf"
export STRIP="${CLANG_BIN}/llvm-strip"
export CLANG_TRIPLE="aarch64-linux-gnu-"

if [ "${MAKE_JOBS_OVERRIDE}" = "auto" ]; then
  MAKE_JOBS="${BUILD_JOBS:-$(nproc)}"
else
  MAKE_JOBS="${MAKE_JOBS_OVERRIDE}"
fi
export TMPDIR="${TMPDIR:-/mnt/ccache/kernel-tmp}"
export TEMP="$TMPDIR"
export TMP="$TMPDIR"
export MAKEFLAGS="-j${MAKE_JOBS} -l${BUILD_LOAD:-$((MAKE_JOBS + 1))}"
START_TIME=$SECONDS

# Keep LOCALVERSION empty to preserve stock vermagic for vendor module compat.
# Branding goes into BUILD_SALT (does not affect UTS_RELEASE / vermagic).
KSU_LOCALVERSION='CONFIG_LOCALVERSION=""'
KSU_BUILD_SALT='CONFIG_BUILD_SALT="deepongi"'

add_gki_defconfig_once() {
  local line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    if ! grep -Fxq "$line" arch/arm64/configs/gki_defconfig; then
      echo "$line" >> arch/arm64/configs/gki_defconfig
    fi
  done
}

sed -i '/^CONFIG_KSU=/d' arch/arm64/configs/gki_defconfig

cat <<EOF | add_gki_defconfig_once
CONFIG_ARM64_CORTEX_X3=y
CONFIG_ARM64_CORTEX_A715=y
CONFIG_ARM64_CORTEX_A510=y
CONFIG_ARM64_VA_BITS=48
CONFIG_ARM64_PA_BITS=48
CONFIG_SCHED_MC=y
CONFIG_SCHED_CORE=y
CONFIG_ENERGY_MODEL=y
CONFIG_CPU_FREQ=y
CONFIG_THERMAL=y
CONFIG_CMA=y
CONFIG_KPROBES=y
CONFIG_HAVE_KPROBES=y
CONFIG_TCP_CONG_ADVANCED=y
CONFIG_TCP_CONG_BBR=y
CONFIG_TCP_CONG_CUBIC=y
CONFIG_TCP_CONG_WESTWOOD=y
CONFIG_TCP_CONG_HTCP=y
CONFIG_TCP_CONG_VEGAS=y
CONFIG_TCP_CONG_VENO=y
CONFIG_TCP_CONG_YEAH=y
CONFIG_TCP_CONG_ILLINOIS=y
CONFIG_TCP_CONG_DCTCP=y
CONFIG_TCP_CONG_CDG=y
CONFIG_DEFAULT_TCP_CONG="bbr"
CONFIG_NET_SCH_FQ=y
CONFIG_IP_SET=y
CONFIG_NET_SCH_CAKE=y
CONFIG_IOSCHED_BFQ=y
CONFIG_BFQ_GROUP_IOSCHED=y
CONFIG_MQ_IOSCHED_DEADLINE=y
CONFIG_MQ_IOSCHED_KYBER=y
CONFIG_DEFAULT_IOSCHED="bfq"
CONFIG_PM_DEVFREQ=y
CONFIG_DEVFREQ_GOV_SIMPLE_ONDEMAND=y
CONFIG_DEVFREQ_GOV_PERFORMANCE=y
CONFIG_DEVFREQ_GOV_POWERSAVE=y
CONFIG_DEVFREQ_GOV_USERSPACE=y
CONFIG_MALI_MIDGARD=m
CONFIG_MALI_PLATFORM_NAME="tensor"
CONFIG_KSU_DEBUG=n
CONFIG_TMPFS_XATTR=y
CONFIG_TMPFS_POSIX_ACL=y
CONFIG_LOCALVERSION_AUTO=n
${KSU_LOCALVERSION}
${KSU_BUILD_SALT}
CONFIG_KSU_LSM_SECURITY_HOOKS=y
EOF

printf '%s\n' 'CONFIG_KSU=y' | add_gki_defconfig_once

if [ "${ENABLE_SUSFS}" = "true" ]; then
  printf '%s\n' 'CONFIG_KSU_SUSFS=y' | add_gki_defconfig_once
fi

rm -f out/.config

make ARCH=arm64 LLVM=1 LLVM_IAS=1 \
  CC="$CC" LD="$LD" AR="$AR" NM="$NM" OBJCOPY="$OBJCOPY" OBJDUMP="$OBJDUMP" \
  READELF="$READELF" STRIP="$STRIP" HOSTCC="$HOSTCC" HOSTCXX="$HOSTCXX" \
  HOSTLD="$HOSTLD" HOSTAR="$HOSTAR" CLANG_TRIPLE="$CLANG_TRIPLE" \
  CROSS_COMPILE="$CROSS_COMPILE" CROSS_COMPILE_COMPAT="$CROSS_COMPILE_COMPAT" \
  O=out gki_defconfig

PROFILE_FRAGMENT=out/pixel8-profile-${TUNING_PROFILE}.config
: > "$PROFILE_FRAGMENT"

case "${TUNING_PROFILE}" in
  performance)
    cat << 'EOF' >> "$PROFILE_FRAGMENT"
CONFIG_HZ_300=y
CONFIG_HZ=300
CONFIG_UCLAMP_TASK=y
CONFIG_LRU_GEN=y
CONFIG_LRU_GEN_ENABLED=y
EOF
    ;;
  battery)
    cat << 'EOF' >> "$PROFILE_FRAGMENT"
CONFIG_HZ_250=y
CONFIG_HZ=250
CONFIG_CPU_IDLE=y
EOF
    ;;
  balanced)
    cat << 'EOF' >> "$PROFILE_FRAGMENT"
CONFIG_HZ_300=y
CONFIG_HZ=300
CONFIG_LRU_GEN=y
CONFIG_LRU_GEN_ENABLED=y
EOF
    ;;
esac

case "${LTO_MODE}" in
  thin)
    cat << 'EOF' >> out/.config
CONFIG_LTO_CLANG_THIN=y
CONFIG_LTO_CLANG_FULL=n
EOF
    ;;
  full)
    cat << 'EOF' >> out/.config
CONFIG_LTO_CLANG_THIN=n
CONFIG_LTO_CLANG_FULL=y
EOF
    ;;
  none)
    cat << 'EOF' >> out/.config
CONFIG_LTO_NONE=y
CONFIG_LTO_CLANG_THIN=n
CONFIG_LTO_CLANG_FULL=n
EOF
    ;;
esac

cat "$PROFILE_FRAGMENT" >> out/.config

# Re-enable BTF: Android 14 bpfloader requires /sys/kernel/btf/vmlinux
# to load network/storage BPF programs at boot. Without it, bpfloader
# fails -> init re-enters loop -> bootloop. Runner installs `dwarves`
# (pahole >= 1.21) in the toolchain step.
cat << 'EOF' >> out/.config
CONFIG_DEBUG_INFO=y
CONFIG_DEBUG_INFO_BTF=y
CONFIG_DEBUG_INFO_REDUCED=n
CONFIG_DEBUG_INFO_COMPRESSED_NONE=y
EOF

if [ "${DIRTY_MODULE_ABI_BYPASS}" = "true" ]; then
  cat << 'EOF' >> out/.config
CONFIG_MODULE_FORCE_LOAD=y
EOF
fi

make ARCH=arm64 LLVM=1 LLVM_IAS=1 \
  CC="$CC" LD="$LD" AR="$AR" NM="$NM" OBJCOPY="$OBJCOPY" OBJDUMP="$OBJDUMP" \
  READELF="$READELF" STRIP="$STRIP" HOSTCC="$HOSTCC" HOSTCXX="$HOSTCXX" \
  HOSTLD="$HOSTLD" HOSTAR="$HOSTAR" CLANG_TRIPLE="$CLANG_TRIPLE" \
  CROSS_COMPILE="$CROSS_COMPILE" CROSS_COMPILE_COMPAT="$CROSS_COMPILE_COMPAT" \
  O=out syncconfig

if grep -q '^CONFIG_SECURITY_SELINUX=y$' out/.config; then
  # KernelSU includes SELinux objsec.h directly; it needs generated flask.h.
  make ARCH=arm64 LLVM=1 LLVM_IAS=1 \
    CC="$CC" LD="$LD" AR="$AR" NM="$NM" OBJCOPY="$OBJCOPY" OBJDUMP="$OBJDUMP" \
    READELF="$READELF" STRIP="$STRIP" HOSTCC="$HOSTCC" HOSTCXX="$HOSTCXX" \
    HOSTLD="$HOSTLD" HOSTAR="$HOSTAR" CLANG_TRIPLE="$CLANG_TRIPLE" \
    CROSS_COMPILE="$CROSS_COMPILE" CROSS_COMPILE_COMPAT="$CROSS_COMPILE_COMPAT" \
    O=out security/selinux/
fi

# Validate critical configs survived Kconfig sync
echo "::group::Config Validation"
CONFIG_ERRORS=0
if ! grep -q '^CONFIG_KSU=y' out/.config; then
  echo "::error::CONFIG_KSU=y not set after Kconfig sync!"
  CONFIG_ERRORS=$((CONFIG_ERRORS + 1))
fi
if [ "${ENABLE_SUSFS}" = "true" ] && ! grep -q '^CONFIG_KSU_SUSFS=y' out/.config; then
  echo "::error::CONFIG_KSU_SUSFS=y not set after Kconfig sync!"
  CONFIG_ERRORS=$((CONFIG_ERRORS + 1))
fi
if [ "$CONFIG_ERRORS" -gt 0 ]; then
  echo "::endgroup::"
  echo "::error::$CONFIG_ERRORS critical config(s) missing. Aborting build to avoid a non-functional kernel."
  echo "::group::Current .config (KSU/SuSFS lines)"
  grep -E 'CONFIG_KSU' out/.config || echo "(none found)"
  echo "::endgroup::"
  exit 1
fi
if ! grep -q '^CONFIG_LRU_GEN=y' out/.config; then
  echo "::warning::CONFIG_LRU_GEN=y (MGLRU) was requested but not set after Kconfig sync. Kernel tree may lack MGLRU support."
fi
echo "Config validation passed"
echo "::endgroup::"

if [ "${FORCE_CLEAN:-false}" = "true" ] && [ "${DIRTY_BUILD:-false}" != "true" ]; then
  make -j$MAKE_JOBS O=out clean
fi

make -j$MAKE_JOBS O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 \
  CC="$CC" LD="$LD" AR="$AR" NM="$NM" OBJCOPY="$OBJCOPY" OBJDUMP="$OBJDUMP" \
  READELF="$READELF" STRIP="$STRIP" HOSTCC="$HOSTCC" HOSTCXX="$HOSTCXX" \
  HOSTLD="$HOSTLD" HOSTAR="$HOSTAR" CLANG_TRIPLE="$CLANG_TRIPLE" \
  CROSS_COMPILE="$CROSS_COMPILE" CROSS_COMPILE_COMPAT="$CROSS_COMPILE_COMPAT" \
  all

trap - EXIT

echo "BUILD_TIME=$((SECONDS - START_TIME))s" >> $GITHUB_ENV
ccache -s | grep -E "(Cacheable calls|Hits|Misses|Hit rate|cache size)" || true
