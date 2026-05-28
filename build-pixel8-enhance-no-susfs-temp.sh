#!/usr/bin/env bash
# Modified: No SuSFS, Dirty Build Support
# Build True Pixel 8 Enhance Kernel (Device-Specific, Not GKI)
#
# This script builds a device-specific kernel for Pixel 8 series (akita/shiba/husky)
# with KernelSU and SuSFS integrated. Unlike the GKI build, this includes all
# device-specific drivers, configs, and device trees required for Pixel 8 to boot.
#
# Requirements:
#   - repo tool installed (/usr/local/bin/repo or in PATH)
#   - 50GB+ free disk space
#   - Build dependencies: git, curl, build-essential, bc, bison, flex, libssl-dev, libelf-dev
#
# Usage:
#   ./build-pixel8-enhance.sh [device] [android_version]
#
# Examples:
#   ./build-pixel8-enhance.sh akita android16
#   ./build-pixel8-enhance.sh shusky android16
#
set -euo pipefail

