#!/bin/bash
# Akita Boot Debug Helper
# Helps diagnose why the kernel won't boot

echo "=========================================="
echo "Akita Boot Debug Helper"
echo "=========================================="
echo ""

echo "## 1. DEVICE CONNECTION TEST"
echo "Checking if device is connected..."
if adb devices | grep -q "device$"; then
  echo "✅ Device connected via ADB"
  DEVICE_STATE="adb"
elif fastboot devices | grep -q "fastboot"; then
  echo "✅ Device in fastboot mode"
  DEVICE_STATE="fastboot"
else
  echo "❌ No device detected"
  echo "   Connect device and enable USB debugging or boot to fastboot"
  DEVICE_STATE="none"
fi

echo ""
echo "## 2. BOOT IMAGE COMPARISON"
if [ -f "boot-akita-android16-"*".img" ]; then
  CUSTOM_BOOT=$(ls -t boot-akita-android16-*.img | head -1)
  STOCK_BOOT="boot-images/stock-akita-cp1a.260505.005.a1.img"
  
  echo "Custom boot: $CUSTOM_BOOT ($(du -h "$CUSTOM_BOOT" | cut -f1))"
  if [ -f "$STOCK_BOOT" ]; then
    echo "Stock boot:  $STOCK_BOOT ($(du -h "$STOCK_BOOT" | cut -f1))"
  fi
  
  echo ""
  echo "Analyzing custom boot image..."
  magiskboot unpack -n "$CUSTOM_BOOT" 2>&1 | grep -E "KERNEL|RAMDISK|HEADER|CMDLINE"
fi

echo ""
echo "## 3. KERNEL CONFIG CHECK"
if [ -f "kernel/out/.config" ]; then
  echo "Checking critical configs..."
  
  CONFIGS=(
    "CONFIG_KSU"
    "CONFIG_KSU_SUSFS"
    "CONFIG_MODULES"
    "CONFIG_MODULE_SIG"
    "CONFIG_MODULE_SIG_FORCE"
    "CONFIG_MODVERSIONS"
  )
  
  for cfg in "${CONFIGS[@]}"; do
    if grep -q "^${cfg}=y" kernel/out/.config; then
      echo "  ✅ $cfg=y"
    elif grep -q "^# ${cfg} is not set" kernel/out/.config; then
      echo "  ❌ $cfg is not set"
    else
      echo "  ⚠️  $cfg not found"
    fi
  done
fi

echo ""
echo "## 4. DEBUGGING STEPS"
echo ""
echo "### Step 1: Test boot without flashing"
echo "  fastboot boot $CUSTOM_BOOT"
echo "  (This tests the image without permanently flashing)"
echo ""
echo "### Step 2: Check boot logs (if device partially boots)"
echo "  adb logcat -b all > boot-log.txt"
echo "  adb shell dmesg > kernel-log.txt"
echo ""
echo "### Step 3: Check fastboot logs"
echo "  fastboot oem log > fastboot-log.txt"
echo "  (May not work on all devices)"
echo ""
echo "### Step 4: Flash and monitor"
echo "  fastboot flash boot $CUSTOM_BOOT"
echo "  fastboot reboot"
echo "  # Immediately run:"
echo "  adb wait-for-device && adb logcat -b all"
echo ""
echo "### Step 5: Recovery options"
echo "  # Flash stock boot to recover:"
echo "  fastboot flash boot boot-images/stock-akita-cp1a.260505.005.a1.img"
echo "  fastboot reboot"
echo ""

if [ "$DEVICE_STATE" = "fastboot" ]; then
  echo "## 5. QUICK TEST"
  echo "Device is in fastboot. Test boot image? (y/n)"
  read -r response
  if [ "$response" = "y" ]; then
    if [ -f "$CUSTOM_BOOT" ]; then
      echo "Testing boot with: $CUSTOM_BOOT"
      fastboot boot "$CUSTOM_BOOT"
    fi
  fi
fi

echo ""
echo "=========================================="
echo "Common boot failure causes:"
echo "  1. Kernel format mismatch (LZ4 vs uncompressed)"
echo "  2. Missing device-specific drivers"
echo "  3. KernelSU/SuSFS causing panic"
echo "  4. SELinux enforcing mode blocking boot"
echo "  5. AVB/dm-verity verification failure"
echo "=========================================="
