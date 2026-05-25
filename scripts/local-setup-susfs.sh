#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_DIR="${ROOT_DIR}/kernel"
KSU_VARIANT="${KSU_VARIANT:-enhance}"

KSU_STAGE="${KERNEL_DIR}/KernelSU"

# Source files from susfs4ksu submodule
SUSFS_SRC="${ROOT_DIR}/susfs4ksu/kernel_patches"

# Patch files
SUSFS_CORE_PATCH="${ROOT_DIR}/.github/patches/${KSU_VARIANT}/50_add_susfs_in_gki-android14-6.1.patch"
SUSFS_KSU_PATCH="${ROOT_DIR}/.github/patches/${KSU_VARIANT}/10_enable_susfs_for_ksu.patch"
NAMESPACE_FIX="${ROOT_DIR}/.github/patches/common/namespace_fix_for_tiann.patch"
ENHANCE_SPOOF_PATCH="${ROOT_DIR}/.github/patches/enhance/20-KernelSU-Spoof-LKM-mode-to-suppress-manager-warning.patch"

MANIFEST="${ROOT_DIR}/logs/patch-manifest-${KSU_VARIANT}.txt"
mkdir -p "$(dirname "$MANIFEST")" "$(dirname "$MANIFEST")/failure-logs"
: > "$MANIFEST"

if [ ! -d "${KSU_STAGE}" ]; then
  echo "error: KSU_STAGE (${KSU_STAGE}) not found. Run KernelSU setup first." >&2
  exit 1
fi

if [ ! -d "${SUSFS_SRC}" ]; then
  echo "error: susfs4ksu source not found at ${SUSFS_SRC}. Ensure submodule is initialized." >&2
  exit 1
fi

echo "Local non-destructive SuSFS setup: variant=${KSU_VARIANT}"

already_applied() {
  if [ -f "${KERNEL_DIR}/fs/susfs.c" ] && [ -f "${KERNEL_DIR}/include/linux/susfs.h" ]; then
    return 0
  fi
  return 1
}

if already_applied; then
  echo "SuSFS source files already present, verifying patches..."
fi

# Step 1: Copy SuSFS source files (idempotent)
echo "Copying SuSFS source files..."
cp -n "${SUSFS_SRC}/fs/susfs.c" "${KERNEL_DIR}/fs/" 2>/dev/null || echo "  fs/susfs.c already exists"
cp -n "${SUSFS_SRC}/include/linux/susfs.h" "${KERNEL_DIR}/include/linux/" 2>/dev/null || echo "  include/linux/susfs.h already exists"
cp -n "${SUSFS_SRC}/include/linux/susfs_def.h" "${KERNEL_DIR}/include/linux/" 2>/dev/null || echo "  include/linux/susfs_def.h already exists"
printf '%s | %s | %s\n' "Copy susfs.c" "susfs4ksu/kernel_patches/fs/susfs.c" "done" >> "$MANIFEST"
printf '%s | %s | %s\n' "Copy susfs.h" "susfs4ksu/kernel_patches/include/linux/susfs.h" "done" >> "$MANIFEST"
printf '%s | %s | %s\n' "Copy susfs_def.h" "susfs4ksu/kernel_patches/include/linux/susfs_def.h" "done" >> "$MANIFEST"

# Step 2: Copy KSU-side patch to KSU_STAGE
cp -n "${SUSFS_SRC}/KernelSU/10_enable_susfs_for_ksu.patch" "${KSU_STAGE}/" 2>/dev/null || echo "  10_enable_susfs_for_ksu.patch already in KSU_STAGE"
printf '%s | %s | %s\n' "Copy KSU-side susfs patch" "susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch" "done" >> "$MANIFEST"

# Step 3: Apply core SuSFS patch (partial ok for namespace.c)
echo "Applying core SuSFS patch..."
cd "${KERNEL_DIR}"
if [ -f "${SUSFS_CORE_PATCH}" ]; then
  CORE_PATCH="${SUSFS_CORE_PATCH}"
else
  CORE_PATCH="${SUSFS_SRC}/50_add_susfs_in_gki-android14-6.1.patch"
fi

if ! patch -p1 --forward --dry-run < "$CORE_PATCH" >/dev/null 2>&1; then
  if patch -p1 --reverse --dry-run < "$CORE_PATCH" >/dev/null 2>&1; then
    echo "Core SuSFS patch already applied, skipping."
    printf '%s | %s | already-applied\n' "Core SuSFS patch" "$CORE_PATCH" >> "$MANIFEST"
  else
    echo "Core SuSFS patch has conflicts, applying with partial OK (namespace.c known issue)..."
    patch -p1 --forward < "$CORE_PATCH" || true

    if [ -f fs/namespace.c.rej ]; then
      echo "Applying namespace.c fix for ${KSU_VARIANT}..."
      if [ -f "${NAMESPACE_FIX}" ]; then
        patch -p1 < "${NAMESPACE_FIX}" || true
      fi
      if [ -f "${ROOT_DIR}/scripts/susfs_namespace_patcher.py" ]; then
        python3 "${ROOT_DIR}/scripts/susfs_namespace_patcher.py" fs/namespace.c --no-backup || true
      else
        echo "susfs_namespace_patcher.py not found, skipping namespace fix"
      fi
      rm -f fs/namespace.c.rej
      printf '%s | %s | applied+namespace-fix\n' "Core SuSFS patch" "$CORE_PATCH" >> "$MANIFEST"
    fi

    if find . -name '*.rej' -print -quit | grep -q .; then
      echo "Unexpected patch rejects after namespace fix:"
      find . -name '*.rej'
      exit 1
    fi
  fi
else
  echo "Core SuSFS patch applies cleanly, applying..."
  patch -p1 --forward < "$CORE_PATCH"
  printf '%s | %s | applied\n' "Core SuSFS patch" "$CORE_PATCH" >> "$MANIFEST"
fi
cd "${ROOT_DIR}"

# Step 4: Apply KSU-side SuSFS integration patch
echo "Applying KernelSU-side SuSFS integration patch..."
cd "${KSU_STAGE}"

if ! grep -q 'config KSU_SUSFS' kernel/Kconfig 2>/dev/null; then
  PATCH_TO_USE="${SUSFS_KSU_PATCH}"
  if [ ! -f "$PATCH_TO_USE" ]; then
    PATCH_TO_USE="${KSU_STAGE}/10_enable_susfs_for_ksu.patch"
  fi

  if [ -f "$PATCH_TO_USE" ]; then
    if patch -p1 --forward --dry-run < "$PATCH_TO_USE" >/dev/null 2>&1; then
      patch -p1 --forward < "$PATCH_TO_USE"
      printf '%s | %s | applied\n' "KSU-side SuSFS patch" "$PATCH_TO_USE" >> "$MANIFEST"
    elif patch -p1 --reverse --dry-run < "$PATCH_TO_USE" >/dev/null 2>&1; then
      echo "KSU-side SuSFS patch already present, skipping."
      printf '%s | %s | already-applied\n' "KSU-side SuSFS patch" "$PATCH_TO_USE" >> "$MANIFEST"
    elif git apply --3way --check "$PATCH_TO_USE" >/dev/null 2>&1; then
      git apply --3way "$PATCH_TO_USE"
      printf '%s | %s | applied-3way\n' "KSU-side SuSFS patch" "$PATCH_TO_USE" >> "$MANIFEST"
    else
      echo "Warning: KSU-side SuSFS patch could not be applied cleanly."
      printf '%s | %s | failed\n' "KSU-side SuSFS patch" "$PATCH_TO_USE" >> "$MANIFEST"
    fi
  else
    echo "Warning: KSU-side SuSFS patch not found at ${PATCH_TO_USE}"
  fi
else
  echo "KSU_SUSFS config already present in Kconfig, skipping KSU-side patch."
  printf '%s | %s | already-present\n' "KSU-side SuSFS integration" "kernel/Kconfig" >> "$MANIFEST"
fi
cd "${ROOT_DIR}"

# Step 5: Ensure selinux_hide compatibility symbols
echo "Ensuring selinux_hide compatibility symbols..."
python3 -c "
from pathlib import Path
feature = Path('${KERNEL_DIR}/kernel/feature/selinux_hide.c')
selinux = Path('${KERNEL_DIR}/kernel/selinux/selinux.c')
if feature.exists():
    text = feature.read_text()
    changed = False
    if 'static struct selinux_state fake_state;' in text:
        text = text.replace('static struct selinux_state fake_state;', 'struct selinux_state fake_state;', 1)
        changed = True
    if 'static bool ksu_selinux_hide_running' in text:
        text = text.replace('static bool ksu_selinux_hide_running', 'bool ksu_selinux_hide_running', 1)
        changed = True
    if changed:
        feature.write_text(text)
        print('selinux_hide.c: promoted static symbols to global')
    else:
        print('selinux_hide.c: symbols already global or file differs')
elif selinux.exists():
    text = selinux.read_text()
    if 'ksu_selinux_hide_running' not in text and 'struct selinux_state fake_state' not in text:
        marker = 'u32 ksu_file_sid __read_mostly = 0;\n'
        compat = marker + '\n#ifdef CONFIG_KSU_SUSFS\nstruct selinux_state fake_state;\nbool ksu_selinux_hide_running __read_mostly = false;\n#endif\n'
        if marker not in text:
            print('selinux.c layout drifted; could not add selinux_hide compat symbols')
        else:
            selinux.write_text(text.replace(marker, compat, 1))
            print('selinux.c: added disabled selinux_hide compatibility symbols')
    else:
        print('selinux_hide compatibility symbols already present')
else:
    print('KernelSU SELinux sources not found; cannot satisfy selinux_hide symbols')
"

# Step 6: Disable setuid_hook.c sus_path call for tiann/kowsu/enhance
if [ "$KSU_VARIANT" = "tiann" ] || [ "$KSU_VARIANT" = "kowsu" ] || [ "$KSU_VARIANT" = "enhance" ]; then
  echo "Disabling missing sus_path loop call for ${KSU_VARIANT}..."
  python3 -c "
from pathlib import Path
target = Path('${KERNEL_DIR}/kernel/hook/setuid_hook.c')
if target.exists():
    text = target.read_text()
    if 'susfs_run_sus_path_loop();' in text:
        target.write_text(text.replace('susfs_run_sus_path_loop();', '(void)0; /* symbol not available in this variant */'))
        print('setuid_hook.c: disabled sus_path loop call')
    else:
        print('setuid_hook.c: sus_path loop already disabled or not present')
"
fi

# Step 7: Apply enhance spoof patch
if [ "$KSU_VARIANT" = "enhance" ] && [ -f "$ENHANCE_SPOOF_PATCH" ]; then
  echo "Applying enhance KernelSU manager compatibility spoof..."
  if patch -d "${KSU_STAGE}" -p1 --forward --dry-run < "$ENHANCE_SPOOF_PATCH" >/dev/null 2>&1; then
    patch -d "${KSU_STAGE}" -p1 --forward < "$ENHANCE_SPOOF_PATCH"
    printf '%s | %s | applied\n' "Enhance manager compatibility spoof" "$ENHANCE_SPOOF_PATCH" >> "$MANIFEST"
  elif patch -d "${KSU_STAGE}" -p1 --reverse --dry-run < "$ENHANCE_SPOOF_PATCH" >/dev/null 2>&1; then
    echo "Enhance spoof patch already present, skipping."
    printf '%s | %s | already-applied\n' "Enhance manager compatibility spoof" "$ENHANCE_SPOOF_PATCH" >> "$MANIFEST"
  else
    echo "Warning: enhance spoof patch could not be applied."
    printf '%s | %s | failed\n' "Enhance manager compatibility spoof" "$ENHANCE_SPOOF_PATCH" >> "$MANIFEST"
  fi
fi

echo "SuSFS local setup complete. Manifest: ${MANIFEST}"
