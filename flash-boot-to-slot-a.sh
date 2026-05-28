#!/bin/bash
set -e

DEVICE="3B101JEKB14425"
BOOT_IMG="boot-akita-android16-6.1.173-20260527.img"

echo "=========================================="
echo "Flash Boot Image to Slot A (Pixel 8a)"
echo "=========================================="
echo ""

# Check if boot image exists
if [ ! -f "$BOOT_IMG" ]; then
  echo "❌ Boot image not found: $BOOT_IMG"
  exit 1
fi

echo "✅ Boot image: $BOOT_IMG ($(du -h "$BOOT_IMG" | cut -f1))"
echo "✅ Target device: $DEVICE (Pixel 8a)"
echo ""

# Check current kernel version
echo "📱 Current kernel version:"
adb -s $DEVICE shell uname -r || echo "  (device not responding)"
echo ""

# Reboot to bootloader
echo "🔄 Rebooting to bootloader..."
adb -s $DEVICE reboot bootloader

# Wait for fastboot
echo "⏳ Waiting for fastboot mode..."
sleep 5
fastboot devices | grep -q . || {
  echo "❌ Device not in fastboot mode"
  echo "   Please manually enter fastboot and run:"
  echo "   fastboot flash boot_a $BOOT_IMG"
  exit 1
}

# Check current slot
echo "📍 Checking current slot..."
CURRENT_SLOT=$(fastboot getvar current-slot 2>&1 | grep "current-slot:" | cut -d: -f2 | tr -d ' ')
echo "   Current slot: $CURRENT_SLOT"

# Flash to slot A
echo ""
echo "🔧 Flashing boot image to slot A..."
fastboot flash boot_a "$BOOT_IMG"

echo ""
echo "✅ Flash complete!"
echo ""

# Ask user if they want to flash slot B too
read -p "Flash to slot B as well for redundancy? (y/n): " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
  echo "🔧 Flashing boot image to slot B..."
  fastboot flash boot_b "$BOOT_IMG"
  echo "✅ Slot B flashed!"
fi

# Reboot
echo ""
echo "🔄 Rebooting device..."
fastboot reboot

# Wait for device to come back online
echo "⏳ Waiting for device to boot..."
adb -s $DEVICE wait-for-device

# Give it a few more seconds to fully boot
sleep 10

# Verify kernel version
echo ""
echo "=========================================="
echo "✅ VERIFICATION"
echo "=========================================="
echo ""
echo "Kernel version:"
adb -s $DEVICE shell uname -a
echo ""
echo "Expected: 6.1.173"
KERNEL_VER=$(adb -s $DEVICE shell uname -r)
if [[ "$KERNEL_VER" == *"6.1.173"* ]]; then
  echo "✅ SUCCESS! Running new kernel 6.1.173"
else
  echo "⚠️  WARNING: Kernel version doesn't match"
  echo "   Got: $KERNEL_VER"
  echo "   Expected: 6.1.173"
fi

echo ""
echo "Checking for KernelSU..."
adb -s $DEVICE shell dmesg | grep -i "kernelsu" | head -5 || echo "  (no KernelSU messages in dmesg yet)"

echo ""
echo "=========================================="
echo "Done! Check KernelSU Manager app now."
echo "=========================================="
