#!/usr/bin/env bash
# CI-optimized Kernel Build Script for AOSP Common with SUSFS support

set -euo pipefail

# Colors for CI
if [ -t 1 ]; then
    RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[34m"; ENDCOLOR="\e[0m"
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; ENDCOLOR=""
fi

log_info()    { echo -e "${GREEN}[INFO]${ENDCOLOR} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${ENDCOLOR} $*"; }
log_error()   { echo -e "${RED}[ERROR]${ENDCOLOR} $*"; exit 1; }
log_step()    { echo -e "${BLUE}==>${ENDCOLOR} $*"; }

# CI-specific defaults
: "${BUILD:=dev}"
: "${PIXEL8A:=y}"
: "${LTO_TYPE:=thin}"
: "${CLANG_PATH:=/tmp/clang-setup/bin}"
: "${ARM64_TOOLCHAIN:=aarch64-none-linux-gnu-}"
: "${ARM32_TOOLCHAIN:=arm-none-eabi-}"
: "${KERNEL_DIR:=.}"
: "${OUT_DIR:=out}"
: "${THREADS:=$(nproc)}"
: "${BUILD_CLEAN:=always}"
: "${CLANG_VERSION:=22.0.0git-20250928}"
: "${KERNEL_BRANCH:=android14-6.1-2025-09}"

# CI detection
if [ -n "${GITHUB_ACTIONS:-}" ]; then
    log_info "Running in GitHub CI environment"
    log_info "Kernel branch: $KERNEL_BRANCH"
    log_info "Clang version: $CLANG_VERSION"
    export CI=true
fi

validate_environment() {
    log_step "Validating build environment"
    
    # Check required tools
    command -v clang >/dev/null || log_error "clang not found"
    command -v make >/dev/null || log_error "make not found"
    command -v patch >/dev/null || log_error "patch not found"
    
    # Check Clang version
    local clang_ver=$(clang --version | head -n1)
    log_info "Using: $clang_ver"
    
    # Check kernel source
    [ -f "Kconfig" ] || log_error "Not in kernel source directory"
    [ -f "Makefile" ] || log_error "Makefile not found"
    
    # Get kernel version
    local kernel_version=$(make kernelversion 2>/dev/null || echo "unknown")
    log_info "Kernel version: $kernel_version"
    
    # Check for SUSFS files
    if [ ! -f "fs/susfs.c" ] && [ ! -f "include/linux/susfs.h" ]; then
        log_warn "SUSFS source files not found - build may fail"
    else
        log_info "SUSFS files detected"
    fi
    
    # Check ARM64 architecture support
    if [ ! -d "arch/arm64" ]; then
        log_error "ARM64 architecture not found in kernel source"
    fi
    
    log_info "Environment validation passed"
}

setup_compiler() {
    log_step "Setting up compiler environment"
    
    export PATH="$CLANG_PATH:$PATH"
    export LLVM=1
    export LLVM_IAS=1
    
    # Verify compiler
    if ! clang --version >/dev/null 2>&1; then
        log_error "Clang compiler not working properly"
    fi
    
    # Verify target architecture support
    if ! aarch64-none-linux-gnu-gcc --version >/dev/null 2>&1; then
        log_warn "ARM64 toolchain may not be properly set up"
    fi
    
    log_info "Compiler setup completed"
}

configure_kernel() {
    log_step "Configuring kernel for AOSP Common"
    
    # Prepare build directory
    if [ "$BUILD_CLEAN" = "always" ] && [ -d "$OUT_DIR" ]; then
        log_info "Cleaning build directory"
        rm -rf "$OUT_DIR"
    fi
    mkdir -p "$OUT_DIR"
    
    log_info "Creating initial defconfig for AOSP Common"
    
    # Use GKI defconfig for AOSP Common
    make O="$OUT_DIR" ARCH=arm64 CC="ccache clang" LD=ld.lld \
         CROSS_COMPILE="$ARM64_TOOLCHAIN" CROSS_COMPILE_COMPAT="$ARM32_TOOLCHAIN" \
         LLVM=1 LLVM_IAS=1 gki_defconfig
    
    # Apply configuration changes for SUSFS and KernelSU
    log_info "Applying kernel configurations for AOSP Common"
    
    local config_file="$OUT_DIR/.config"
    
    # KernelSU base
    echo "CONFIG_KSU=y" >> "$config_file"
    
    # SUSFS features
    echo "CONFIG_KSU_SUSFS=y" >> "$config_file"
    echo "CONFIG_KSU_SUSFS_SUS_PATH=y" >> "$config_file"
    echo "CONFIG_KSU_SUSFS_SUS_MOUNT=y" >> "$config_file"
    echo "CONFIG_KSU_SUSFS_SUS_KSTAT=y" >> "$config_file"
    echo "CONFIG_KSU_SUSFS_TRY_UMOUNT=y" >> "$config_file"
    echo "CONFIG_KSU_SUSFS_SPOOF_UNAME=y" >> "$config_file"
    echo "CONFIG_KSU_SUSFS_ENABLE_LOG=y" >> "$config_file"
    echo "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y" >> "$config_file"
    
    # Additional useful configs for AOSP
    echo "CONFIG_IKCONFIG=y" >> "$config_file"
    echo "CONFIG_IKCONFIG_PROC=y" >> "$config_file"
    echo "CONFIG_MODULES=y" >> "$config_file"
    echo "CONFIG_MODULE_UNLOAD=y" >> "$config_file"
    
    # LTO configuration
    case "$LTO_TYPE" in
        thin) 
            echo "CONFIG_LTO_CLANG_THIN=y" >> "$config_file"
            echo "CONFIG_THINLTO=y" >> "$config_file"
            ;;
        full) 
            echo "CONFIG_LTO_CLANG_FULL=y" >> "$config_file"
            ;;
        none) 
            echo "CONFIG_LTO_NONE=y" >> "$config_file"
            ;;
    esac
    
    # Pixel 8a specific configs if enabled
    if [ "$PIXEL8A" = "y" ]; then
        log_info "Enabling Pixel 8a configurations"
        echo "CONFIG_ARM64_CORTEX_X3=y" >> "$config_file"
        echo "CONFIG_ARM64_CORTEX_A715=y" >> "$config_file"
        echo "CONFIG_ARM64_CORTEX_A510=y" >> "$config_file"
        echo "CONFIG_SCHED_MC=y" >> "$config_file"
        echo "CONFIG_SCHED_CORE=y" >> "$config_file"
    fi
    
    # Update config to resolve dependencies
    log_info "Updating kernel configuration"
    make O="$OUT_DIR" ARCH=arm64 CC="ccache clang" LD=ld.lld \
         CROSS_COMPILE="$ARM64_TOOLCHAIN" CROSS_COMPILE_COMPAT="$ARM32_TOOLCHAIN" \
         LLVM=1 LLVM_IAS=1 olddefconfig
    
    # Verify final config
    if grep -q "CONFIG_KSU=y" "$config_file"; then
        log_info "✓ KernelSU enabled in final config"
    else
        log_warn "KernelSU not enabled in final config"
    fi
    
    if grep -q "CONFIG_KSU_SUSFS=y" "$config_file"; then
        log_info "✓ SUSFS enabled in final config"
    else
        log_warn "SUSFS not enabled in final config"
    fi
    
    log_info "Kernel configuration completed"
}

build_kernel() {
    log_step "Building AOSP Common kernel"
    
    local start_time=$(date +%s)
    
    log_info "Starting kernel build with $THREADS threads"
    log_info "Build type: $BUILD, LTO: $LTO_TYPE, Pixel8a: $PIXEL8A"
    
    # Build the kernel
    make -j"$THREADS" O="$OUT_DIR" ARCH=arm64 CC="ccache clang" LD=ld.lld \
         CROSS_COMPILE="$ARM64_TOOLCHAIN" CROSS_COMPILE_COMPAT="$ARM32_TOOLCHAIN" \
         LLVM=1 LLVM_IAS=1
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    log_info "Build completed in ${duration}s"
    
    # Verify build outputs
    local kernel_image="$OUT_DIR/arch/arm64/boot/Image"
    if [ -f "$kernel_image" ]; then
        local image_size=$(du -h "$kernel_image" | cut -f1)
        log_info "✓ Kernel image created: $kernel_image ($image_size)"
    else
        log_error "✗ Kernel image not found at: $kernel_image"
    fi
    
    # Check for additional build artifacts
    if [ -f "$OUT_DIR/System.map" ]; then
        log_info "✓ System.map generated"
    fi
    
    if [ -f "$OUT_DIR/.config" ]; then
        log_info "✓ Kernel config preserved"
    fi
    
    # Check for modules if any
    if [ -d "$OUT_DIR/vendor/lib/modules" ] || [ -d "$OUT_DIR/lib/modules" ]; then
        log_info "✓ Kernel modules built"
    fi
}

package_kernel() {
    log_step "Packaging kernel for distribution"
    
    local image="$OUT_DIR/arch/arm64/boot/Image"
    local kernel_version=$(make kernelversion 2>/dev/null | tr -d '\n' || echo "unknown")
    
    # Create build label (UTC timestamp + short SHA + kernel version)
    local build_label
    if [ -n "${GITHUB_SHA:-}" ]; then
        build_label="$(date -u +"%Y%m%dT%H%MZ")-${GITHUB_SHA:0:7}-${kernel_version}"
    else
        build_label="$(date -u +"%Y%m%dT%H%MZ")-${kernel_version}"
    fi
    
    local zip_name="AK3-A14-6.1.155-MKSU-${build_label}-${BUILD}.zip"
    
    # Package with AnyKernel3 if available
    if [ -d "AnyKernel3-p8a" ]; then
        log_info "Packaging with AnyKernel3"
        
        # Clean AnyKernel3 directory
        rm -f AnyKernel3-p8a/Image
        rm -f AnyKernel3-p8a/*.zip
        
        # Copy kernel image
        cp "$image" AnyKernel3-p8a/
        
        # Update anykernel.sh with build info
        sed -i "s|kernel.string=.*|kernel.string=AOSP Common ${kernel_version} with SUSFS ${build_label}|" AnyKernel3-p8a/anykernel.sh
        
        # Create flashable zip
        cd AnyKernel3-p8a
        zip -r9 "../$zip_name" ./* -x ".git*" "README.md" "LICENSE"
        cd ..
        
        # Move to builds directory
        mkdir -p builds/6.1.155
        mv "$zip_name" builds/6.1.155/
        
        log_info "✓ Kernel packaged: builds/6.1.155/$zip_name"
        ls -la "builds/6.1.155/$zip_name"
    else
        log_warn "AnyKernel3 directory not found, creating minimal package"
        
        mkdir -p builds/6.1.155
        local raw_image_name="Image-${build_label}"
        cp "$image" "builds/6.1.155/${raw_image_name}"
        
        # Create a simple info file
        echo "Kernel: AOSP Common ${kernel_version}" > "builds/6.1.155/build-info.txt"
        echo "Build: ${build_label}" >> "builds/6.1.155/build-info.txt"
        echo "Clang: ${CLANG_VERSION}" >> "builds/6.1.155/build-info.txt"
        echo "LTO: ${LTO_TYPE}" >> "builds/6.1.155/build-info.txt"
        echo "SUSFS: Integrated" >> "builds/6.1.155/build-info.txt"
        
        log_info "✓ Raw kernel image: builds/6.1.155/${raw_image_name}"
    fi
}

main() {
    log_step "Starting AOSP Common kernel build with SUSFS support"
    log_info "Build parameters:"
    log_info "  - Kernel: $KERNEL_BRANCH"
    log_info "  - Build: $BUILD" 
    log_info "  - LTO: $LTO_TYPE"
    log_info "  - Pixel8a: $PIXEL8A"
    log_info "  - Clang: $CLANG_VERSION"
    
    validate_environment
    setup_compiler
    configure_kernel
    build_kernel
    package_kernel
    
    log_info "✓ Build completed successfully! 🎉"
    
    # Final summary
    echo "=========================================="
    echo "Build Summary:"
    echo "  - Kernel: AOSP Common $KERNEL_BRANCH"
    echo "  - Output: builds/6.1.155/"
    echo "  - Clang: $CLANG_VERSION"
    echo "  - LTO: $LTO_TYPE"
    echo "  - SUSFS: Integrated"
    echo "  - KernelSU: Enabled"
    echo "=========================================="
}

main "$@"
