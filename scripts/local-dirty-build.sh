#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_DIR="${ROOT_DIR}/kernel"

if [ ! -d "${KERNEL_DIR}" ]; then
  echo "error: kernel source not found at ${KERNEL_DIR}" >&2
  echo "hint: run git submodule update --init --recursive first" >&2
  exit 1
fi

if [ ! -f "${ROOT_DIR}/.github/scripts/build-kernel.sh" ]; then
  echo "error: missing .github/scripts/build-kernel.sh" >&2
  exit 1
fi

if [ -x "/mnt/Hawai/toolchains/Clang-23.0.0git-20260130/bin/clang" ] && [ -d "/mnt/Hawai/toolchains" ]; then
  DEFAULT_CLANG_BIN="/mnt/Hawai/toolchains/Clang-23.0.0git-20260130/bin"
  DEFAULT_ARM64_TOOLCHAIN="/mnt/Hawai/toolchains/arm-gnu-toolchain-15.2.rel1-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-"
  DEFAULT_ARM32_TOOLCHAIN="/mnt/Hawai/toolchains/arm-gnu-toolchain-15.2.rel1-x86_64-arm-none-eabi/bin/arm-none-eabi-"
else
  CLANG_PATH="$(command -v clang || true)"
  if [ -z "${CLANG_PATH}" ]; then
    echo "error: clang not found in PATH and local toolchain is unavailable" >&2
    exit 1
  fi
  DEFAULT_CLANG_BIN="$(dirname "${CLANG_PATH}")"
  DEFAULT_ARM64_TOOLCHAIN="aarch64-linux-gnu-"
  DEFAULT_ARM32_TOOLCHAIN="arm-linux-gnueabihf-"
fi

export GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-${ROOT_DIR}}"
export KSU_VARIANT="${KSU_VARIANT:-enhance}"
export ENABLE_SUSFS="${ENABLE_SUSFS:-true}"
export FORCE_CLEAN="false"
export DIRTY_BUILD="true"
export DIRTY_MODULE_ABI_BYPASS="${DIRTY_MODULE_ABI_BYPASS:-true}"
export TUNING_PROFILE="${TUNING_PROFILE:-balanced}"
export LTO_MODE="${LTO_MODE:-thin}"
export MAKE_JOBS_OVERRIDE="${MAKE_JOBS_OVERRIDE:-auto}"
export BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
export BUILD_LOAD="${BUILD_LOAD:-$((BUILD_JOBS + 1))}"
export CLANG_BIN="${CLANG_BIN:-${DEFAULT_CLANG_BIN}}"
export ARM64_TOOLCHAIN="${ARM64_TOOLCHAIN:-${DEFAULT_ARM64_TOOLCHAIN}}"
export ARM32_TOOLCHAIN="${ARM32_TOOLCHAIN:-${DEFAULT_ARM32_TOOLCHAIN}}"
export CCACHE_DIR="${CCACHE_DIR:-${HOME}/.ccache}"
export TMPDIR="${TMPDIR:-/tmp/kernel-build}"

mkdir -p "${ROOT_DIR}/logs" "${CCACHE_DIR}" "${TMPDIR}"

if [ ! -d "${KERNEL_DIR}/drivers/kernelsu" ] && [ ! -d "${KERNEL_DIR}/KernelSU" ]; then
  echo "warning: KernelSU does not appear to be integrated in ${KERNEL_DIR}" >&2
  echo "warning: this wrapper preserves the dirty tree and does not sync/apply workflow patches" >&2
fi

if [ "${ENABLE_SUSFS}" = "true" ] && [ ! -f "${KERNEL_DIR}/fs/susfs.c" ]; then
  echo "SuSFS enabled but not yet applied. Running local-setup-susfs.sh..."
  bash "${ROOT_DIR}/scripts/local-setup-susfs.sh"
elif [ "${ENABLE_SUSFS}" = "true" ]; then
  echo "SuSFS source files already present in kernel tree."
fi

echo "Dirty local build: variant=${KSU_VARIANT}, susfs=${ENABLE_SUSFS}, jobs=${BUILD_JOBS}, clang=${CLANG_BIN}"
cd "${ROOT_DIR}"
bash .github/scripts/build-kernel.sh
