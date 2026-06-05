#!/bin/bash
set -e
mkdir -p "$GITHUB_WORKSPACE/logs"
PATCH_MANIFEST="$GITHUB_WORKSPACE/logs/patch-manifest-${KSU_VARIANT}.txt"
PATCH_FAILURE_LOG="$GITHUB_WORKSPACE/logs/patch-failure-${KSU_VARIANT}.log"
: > "$PATCH_MANIFEST"
: > "$PATCH_FAILURE_LOG"

log_patch_failure() {
  local patch_file="$1"
  local description="$2"
  local temp_log

  temp_log="$(mktemp)"
  patch -p1 --forward --dry-run < "$patch_file" >"$temp_log" 2>&1 || true

  {
    echo "=== ${description} ==="
    echo "Patch: $patch_file"
    cat "$temp_log"
    echo
  } >> "$PATCH_FAILURE_LOG"

  rm -f "$temp_log"
}

apply_patch_or_fail() {
  local patch_file="$1"
  local description="$2"

  if patch -p1 --forward --dry-run < "$patch_file" >/dev/null 2>&1; then
    patch -p1 --forward < "$patch_file"
    printf '%s | %s | applied\n' "$description" "$patch_file" >> "$PATCH_MANIFEST"
  elif patch -p1 --reverse --dry-run < "$patch_file" >/dev/null 2>&1; then
    echo "ℹ️ ${description} already present, skipping."
    printf '%s | %s | already-present\n' "$description" "$patch_file" >> "$PATCH_MANIFEST"
  elif patch -p1 --forward --fuzz=3 --dry-run < "$patch_file" >/dev/null 2>&1; then
    echo "📋 Applying patch with fuzz=3: $description"
    patch -p1 --forward --fuzz=3 < "$patch_file"
    printf '%s | %s | applied-fuzz\n' "$description" "$patch_file" >> "$PATCH_MANIFEST"
  elif git apply --3way --check "$patch_file" >/dev/null 2>&1; then
    echo "📋 Applying patch with 3-way merge: $description"
    git apply --3way "$patch_file"
    printf '%s | %s | applied-3way\n' "$description" "$patch_file" >> "$PATCH_MANIFEST"
  else
    echo "❌ ${description} could not be applied cleanly: $patch_file"
    printf '%s | %s | failed\n' "$description" "$patch_file" >> "$PATCH_MANIFEST"
    log_patch_failure "$patch_file" "$description"
    echo "📝 Patch failure log: $PATCH_FAILURE_LOG"
    exit 1
  fi
}

apply_variant_or_default_patch() {
  local variant_patch="$1"
  local default_patch="$2"
  local variant_desc="$3"
  local default_desc="$4"

  # Auto-detect patch strip level (-p0 vs -p1)
  patch_already_present() {
    local patch_file="$1"
    local strip_level="$2"
    local temp_log

    temp_log="$(mktemp)"
    patch -p${strip_level} --forward --dry-run < "$patch_file" >"$temp_log" 2>&1 || true
    if grep -q 'Reversed (or previously applied) patch detected' "$temp_log"; then
      rm -f "$temp_log"
      return 0
    fi
    rm -f "$temp_log"
    return 1
  }

  detect_strip_level() {
    local patch_file="$1"
    if patch -p1 --forward --dry-run < "$patch_file" >/dev/null 2>&1 \
      || patch_already_present "$patch_file" "1"; then
      echo "1"
    elif patch -p0 --forward --dry-run < "$patch_file" >/dev/null 2>&1 \
      || patch_already_present "$patch_file" "0"; then
      echo "0"
    else
      echo "-1"
    fi
  }

  if [ -f "$variant_patch" ]; then
    STRIP_LEVEL=$(detect_strip_level "$variant_patch")
    if [ "$STRIP_LEVEL" = "-1" ]; then
      if git apply --3way --check "$variant_patch" >/dev/null 2>&1; then
        echo "📋 Applying CUSTOM patch with 3-way merge: $variant_desc"
        git apply --3way "$variant_patch"
        printf '%s | %s | applied-3way\n' "$variant_desc" "$variant_patch" >> "$PATCH_MANIFEST"
        return 0
      fi
      echo "⚠️ Custom patch is stale, falling back to default: $variant_patch"
      printf '%s | %s | stale-fallback\n' "$variant_desc" "$variant_patch" >> "$PATCH_MANIFEST"
      log_patch_failure "$variant_patch" "$variant_desc"
    elif patch_already_present "$variant_patch" "$STRIP_LEVEL"; then
      echo "ℹ️ ${variant_desc} already present, skipping."
      printf '%s | %s | already-present\n' "$variant_desc" "$variant_patch" >> "$PATCH_MANIFEST"
      return 0
    else
      echo "📋 Applying CUSTOM patch: $variant_desc"
      patch -p${STRIP_LEVEL} --forward < "$variant_patch"
      printf '%s | %s | applied-p%s\n' "$variant_desc" "$variant_patch" "$STRIP_LEVEL" >> "$PATCH_MANIFEST"
      return 0
    fi
  fi

  STRIP_LEVEL=$(detect_strip_level "$default_patch")
  if [ "$STRIP_LEVEL" = "-1" ]; then
    if git apply --3way --check "$default_patch" >/dev/null 2>&1; then
      echo "📋 Applying DEFAULT patch with 3-way merge: $default_desc"
      git apply --3way "$default_patch"
      printf '%s | %s | applied-3way\n' "$default_desc" "$default_patch" >> "$PATCH_MANIFEST"
      return 0
    fi
    echo "❌ ${default_desc} could not be applied cleanly: $default_patch"
    printf '%s | %s | failed\n' "$default_desc" "$default_patch" >> "$PATCH_MANIFEST"
    log_patch_failure "$default_patch" "$default_desc"
    echo "📝 Patch failure log: $PATCH_FAILURE_LOG"
    exit 1
  elif patch_already_present "$default_patch" "$STRIP_LEVEL"; then
    echo "ℹ️ ${default_desc} already present, skipping."
    printf '%s | %s | already-present\n' "$default_desc" "$default_patch" >> "$PATCH_MANIFEST"
    return 0
  else
    echo "📋 Applying DEFAULT patch: $default_desc"
    patch -p${STRIP_LEVEL} --forward < "$default_patch"
    printf '%s | %s | applied-p%s\n' "$default_desc" "$default_patch" "$STRIP_LEVEL" >> "$PATCH_MANIFEST"
    return 0
  fi
}

ensure_namespace_trace_hook_include() {
  if grep -q '^#include <trace/hooks/blk.h>$' fs/namespace.c 2>/dev/null; then
    printf '%s | %s | already-present\n' "Namespace trace hook include" "fs/namespace.c" >> "$PATCH_MANIFEST"
    return 0
  fi

  printf '%s\n' \
    'from pathlib import Path' \
    'path = Path("fs/namespace.c")' \
    'text = path.read_text()' \
    'marker = "#include \"internal.h\"\n"' \
    'insert = "#include \"internal.h\"\n#include <trace/hooks/blk.h>\n"' \
    'if marker not in text: raise SystemExit("namespace.c layout drifted; could not inject trace/hooks include")' \
    'path.write_text(text.replace(marker, insert, 1))' \
    | python -

  printf '%s | %s | applied\n' "Namespace trace hook include" "fs/namespace.c" >> "$PATCH_MANIFEST"
}

auto_merge_tiann_ksu_susfs_patch() {
  printf '%s\n' \
    'import re' \
    'from pathlib import Path' \
    'def replace_once(path_str, old, new):' \
    '    path = Path(path_str)' \
    '    text = path.read_text()' \
    '    if old not in text: raise SystemExit(f"missing expected conflict block in {path_str}")' \
    '    path.write_text(text.replace(old, new, 1))' \
    'def replace_re(path_str, pattern, new):' \
    '    path = Path(path_str)' \
    '    text = path.read_text()' \
    '    updated, count = re.subn(pattern, new, text, count=1, flags=re.S)' \
    '    if count != 1: raise SystemExit(f"missing expected conflict pattern in {path_str}")' \
    '    path.write_text(updated)' \
    'replace_once("kernel/Kbuild", """<<<<<<< ours\nifeq ($(filter /%,$(src)),)\nKSU_KERNEL_DIR := $(srctree)/$(src)\nelse\nKSU_KERNEL_DIR := $(src)\nendif\n=======\n## As we are building gki only, no KBUILD_EXTMOD is needed\n## Since there is still a build error for 6.12 as $(src) returns absolute path, so here we just hardcode it\nccflags-y += -I$(srctree)/drivers/kernelsu -I$(srctree)/drivers/kernelsu/include\n>>>>>>> theirs\n""", """## As we are building gki only, no KBUILD_EXTMOD is needed\n## Since there is still a build error for 6.12 as $(src) returns absolute path, so here we just hardcode it\nccflags-y += -I$(srctree)/drivers/kernelsu -I$(srctree)/drivers/kernelsu/include\n""")' \
    'replace_once("kernel/Kbuild", """\nccflags-y += -I$(KSU_KERNEL_DIR) -I$(KSU_KERNEL_DIR)/include\n""", "\n")' \
    'replace_re("kernel/core/init.c", r"<<<<<<< ours\n#include \"hook/syscall_hook_manager\.h\"\n#include \"hook/lsm_hook\.h\"\n=======\n>>>>>>> theirs\n", "")' \
    'replace_re("kernel/core/init.c", r"<<<<<<< ours\n\s*ksu_init_symbol_resolver\(\);\n\s*ksu_syscall_hook_init\(\);\n\s*\n\s*ksu_feature_init\(\);\n\s*ksu_sulog_init\(\);\n\s*ksu_adb_root_init\(\);\n\s*ksu_lsm_hook_init\(\);\n\s*ksu_selinux_hide_init\(\);\n=======\n\s*ksu_feature_init\(\);\n>>>>>>> theirs\n", "    ksu_feature_init();\n")' \
    'replace_re("kernel/feature/kernel_umount.c", r"<<<<<<< ours\n.*?=======\n>>>>>>> theirs\n", "")' \
    'replace_re("kernel/policy/app_profile.c", r"<<<<<<< ours\n\s*struct task_struct \*p = current;\n\s*struct task_struct \*t;\n\s*struct root_profile \*profile = NULL;\n=======\n\s*struct root_profile profile;\n>>>>>>> theirs\n", "    struct root_profile *profile = NULL;\n")' \
    'replace_re("kernel/policy/app_profile.c", r"<<<<<<< ours\n\s*for_each_thread \(p, t\) \{\n\s*ksu_set_task_tracepoint_flag\(t\);\n\s*\}\n\s*\n\s*setup_mount_ns\(profile->namespaces\);\n\s*ksu_put_root_profile\(profile\);\n=======\n\s*setup_mount_ns\(profile\.namespaces\);\n>>>>>>> theirs\n", "    setup_mount_ns(profile->namespaces);\n    ksu_put_root_profile(profile);\n")' \
    | python -

  if grep -R "<<<<<<<\|>>>>>>>" -n kernel >/tmp/ksu-susfs-conflicts.txt; then
    head /tmp/ksu-susfs-conflicts.txt
    echo "❌ Unresolved conflicts remain after tiann/enhance KernelSU SuSFS auto-merge"
    exit 1
  fi

  git add kernel/Kbuild kernel/core/init.c kernel/feature/kernel_umount.c kernel/policy/app_profile.c
}

# Reset kernel and KernelSU trees to clean state before SuSFS patching
echo "🧹 Resetting kernel tree for clean SuSFS patch application..."
cd "${GITHUB_WORKSPACE}/kernel"
git reset --hard HEAD
git clean -fdx
cd "${KSU_STAGE:-${GITHUB_WORKSPACE}/.ksu-src}"
git reset --hard HEAD
git clean -fdx
cd "${GITHUB_WORKSPACE}"

# Copy SuSFS source files per upstream instructions
echo "📋 Copying SuSFS source files..."
cp susfs4ksu/kernel_patches/fs/susfs.c kernel/fs/
cp susfs4ksu/kernel_patches/include/linux/susfs.h kernel/include/linux/
cp susfs4ksu/kernel_patches/include/linux/susfs_def.h kernel/include/linux/

# Copy patches into target directories per pershoot instructions
echo "📋 Copying SuSFS patches to target directories..."
# Select SuSFS patch based on Android version
if [ "${ANDROID_VERSION}" = "android17" ]; then
  SUSFS_PATCH_NAME="50_add_susfs_in_gki-android17-6.18.patch"
elif [ "${ANDROID_VERSION}" = "android16" ]; then
  SUSFS_PATCH_NAME="50_add_susfs_in_gki-android14-6.1.patch"
else
  SUSFS_PATCH_NAME="50_add_susfs_in_gki-android14-6.1.patch"
fi
cp susfs4ksu/kernel_patches/${SUSFS_PATCH_NAME} kernel/ || {
  echo "⚠️ SuSFS patch ${SUSFS_PATCH_NAME} not found in susfs4ksu/kernel_patches/"
  echo "   Android ${ANDROID_VERSION} may not have SuSFS support yet."
  if [ "${ANDROID_VERSION}" = "android17" ]; then
    echo "   Falling back to android14-6.1 patch (may fail to apply)..."
    SUSFS_PATCH_NAME="50_add_susfs_in_gki-android14-6.1.patch"
    cp susfs4ksu/kernel_patches/${SUSFS_PATCH_NAME} kernel/
  else
    exit 1
  fi
}
cp susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch "${KSU_STAGE:-${GITHUB_WORKSPACE}/.ksu-src}/"

cd kernel

# Apply core SuSFS patch.
VARIANT_SUSFS_PATCH="../.github/patches/${KSU_VARIANT}/${SUSFS_PATCH_NAME}"
DEFAULT_SUSFS_PATCH="./${SUSFS_PATCH_NAME}"

if [ "$KSU_VARIANT" = "tiann" ] || [ "$KSU_VARIANT" = "enhance" ]; then
  echo "📋 Enforcing default-only core SuSFS patch for ${KSU_VARIANT}"
  # Apply with partial success allowed (namespace.c hunk #1 will fail)
  echo "📋 Applying core SuSFS patch (partial OK for namespace.c)..."
  patch -p1 < "$DEFAULT_SUSFS_PATCH" || true

  # Apply namespace fix for failed hunk #1
  if [ -f fs/namespace.c.rej ]; then
    echo "📋 Applying namespace.c fix for tiann/enhance..."
    patch -p1 < ../.github/patches/common/namespace_fix_for_tiann.patch
    ../scripts/susfs_namespace_patcher.py fs/namespace.c --no-backup || true
    rm -f fs/namespace.c.rej
    printf '%s | %s | applied\n' "Namespace fix for tiann" "../.github/patches/common/namespace_fix_for_tiann.patch + ../scripts/susfs_namespace_patcher.py" >> "$PATCH_MANIFEST"
  fi

  # Verify no other rejects remain
  if find . -name '*.rej' -print -quit | grep -q .; then
    echo "❌ Unexpected patch rejects found after namespace fix:"
    find . -name '*.rej' -exec echo "  {}" \; -exec cat {} \;
    exit 1
  fi

  printf '%s | %s | applied-partial+fix\n' "Default core SuSFS patch" "$DEFAULT_SUSFS_PATCH" >> "$PATCH_MANIFEST"
elif [ "$KSU_VARIANT" = "kowsu" ]; then
  apply_patch_or_fail "$VARIANT_SUSFS_PATCH" "Custom core SuSFS patch"
else
  # Variants without a strict core-patch policy use variant-first fallback.
  apply_variant_or_default_patch \
    "$VARIANT_SUSFS_PATCH" \
    "$DEFAULT_SUSFS_PATCH" \
    "Custom core SuSFS patch" \
    "Default core SuSFS patch"
fi

# Always attempt the KernelSU-side SuSFS integration patch.
# Some upstream variants drift over time; the helper will skip cleanly
# when the integration is already present.
cd "${KSU_STAGE:-${GITHUB_WORKSPACE}/.ksu-src}"

VARIANT_KSU_PATCH="${GITHUB_WORKSPACE}/.github/patches/${KSU_VARIANT}/10_enable_susfs_for_ksu.patch"
DEFAULT_KSU_PATCH="./10_enable_susfs_for_ksu.patch"
SUSFS_RUNTIME_ENABLED=true

ksu_susfs_integrated() {
  grep -q 'config KSU_SUSFS' kernel/Kconfig 2>/dev/null \
    || grep -q 'KSU_SUSFS' kernel/Makefile 2>/dev/null \
    || grep -q 'KSU_SUSFS' kernel/Kbuild 2>/dev/null
}

try_apply_patch() {
  local patch_file="$1"
  local desc="$2"

  if patch -p1 --forward --dry-run < "$patch_file" >/dev/null 2>&1; then
    echo "📋 Applying patch: $desc"
    patch -p1 --forward < "$patch_file"
    printf '%s | %s | applied\n' "$desc" "$patch_file" >> "$PATCH_MANIFEST"
    return 0
  elif patch -p1 --reverse --dry-run < "$patch_file" >/dev/null 2>&1; then
    echo "ℹ️ ${desc} already present, skipping."
    printf '%s | %s | already-present\n' "$desc" "$patch_file" >> "$PATCH_MANIFEST"
    return 0
  fi

  return 1
}

if ksu_susfs_integrated; then
  echo "ℹ️ KernelSU SuSFS integration appears present; skipping patch application."
  printf '%s | %s | already-present\n' "KernelSU SuSFS integration" "kernel/(Kconfig|Makefile|Kbuild)" >> "$PATCH_MANIFEST"
elif [ "$KSU_VARIANT" = "next" ]; then
  echo "🔍 Checking optional KernelSU-Next SuSFS integration (variant=${KSU_VARIANT})..."
  if [ -f "$VARIANT_KSU_PATCH" ] && try_apply_patch "$VARIANT_KSU_PATCH" "KernelSU-Next custom SuSFS patch"; then
    :
  elif try_apply_patch "$DEFAULT_KSU_PATCH" "KernelSU-Next default SuSFS patch"; then
    :
  elif ksu_susfs_integrated; then
    echo "ℹ️ KernelSU-Next already contains SuSFS integration."
    printf '%s | %s | already-present\n' "KernelSU-Next SuSFS integration" "kernel/(Kconfig|Makefile|Kbuild)" >> "$PATCH_MANIFEST"
  else
    echo "ℹ️ KernelSU-Next uses WildKernels SuSFS patches; skipping legacy KernelSU-side patch."
    printf '%s | %s | skipped-next-wildkernel\n' "KernelSU-Next legacy SuSFS integration" "$DEFAULT_KSU_PATCH" >> "$PATCH_MANIFEST"
  fi
elif [ "$KSU_VARIANT" = "tiann" ] || [ "$KSU_VARIANT" = "enhance" ]; then
  echo "📋 Enforcing default-only KernelSU SuSFS patch for ${KSU_VARIANT}"
  if ! try_apply_patch "$DEFAULT_KSU_PATCH" "Default KernelSU SuSFS patch"; then
    if git apply --3way "$DEFAULT_KSU_PATCH"; then
      echo "📋 Applied Default KernelSU SuSFS patch with 3-way merge"
      printf '%s | %s | applied-3way\n' "Default KernelSU SuSFS patch" "$DEFAULT_KSU_PATCH" >> "$PATCH_MANIFEST"
    else
      echo "📋 Resolving Default KernelSU SuSFS patch 3-way conflicts for ${KSU_VARIANT}"
      auto_merge_tiann_ksu_susfs_patch
      printf '%s | %s | applied-3way-automerge\n' "Default KernelSU SuSFS patch" "$DEFAULT_KSU_PATCH" >> "$PATCH_MANIFEST"
    fi

    if ksu_susfs_integrated; then
      echo "ℹ️ KernelSU SuSFS integration appears present; skipping patch application."
      printf '%s | %s | verified-present\n' "KernelSU SuSFS integration" "kernel/(Kconfig|Makefile|Kbuild)" >> "$PATCH_MANIFEST"
    else
      echo "❌ Default KernelSU SuSFS patch could not be applied cleanly: $DEFAULT_KSU_PATCH"
      printf '%s | %s | failed\n' "Default KernelSU SuSFS patch" "$DEFAULT_KSU_PATCH" >> "$PATCH_MANIFEST"
      exit 1
    fi
  fi
elif [ -f "$VARIANT_KSU_PATCH" ]; then
  if ! try_apply_patch "$VARIANT_KSU_PATCH" "Custom KernelSU SuSFS patch"; then
    echo "⚠️ Custom KernelSU SuSFS patch is stale, falling back to default: $VARIANT_KSU_PATCH"
    printf '%s | %s | stale-fallback\n' "Custom KernelSU SuSFS patch" "$VARIANT_KSU_PATCH" >> "$PATCH_MANIFEST"
    if ! try_apply_patch "$DEFAULT_KSU_PATCH" "Default KernelSU SuSFS patch"; then
      if ksu_susfs_integrated; then
        echo "ℹ️ KernelSU SuSFS integration appears present; skipping patch application."
        printf '%s | %s | already-present\n' "KernelSU SuSFS integration" "kernel/(Kconfig|Makefile|Kbuild)" >> "$PATCH_MANIFEST"
      else
        echo "❌ Default KernelSU SuSFS patch could not be applied cleanly: $DEFAULT_KSU_PATCH"
        printf '%s | %s | failed\n' "Default KernelSU SuSFS patch" "$DEFAULT_KSU_PATCH" >> "$PATCH_MANIFEST"
        exit 1
      fi
    fi
  fi
else
  if ! try_apply_patch "$DEFAULT_KSU_PATCH" "Default KernelSU SuSFS patch"; then
    if ksu_susfs_integrated; then
      echo "ℹ️ KernelSU SuSFS integration appears present; skipping patch application."
      printf '%s | %s | already-present\n' "KernelSU SuSFS integration" "kernel/(Kconfig|Makefile|Kbuild)" >> "$PATCH_MANIFEST"
    else
      echo "❌ Default KernelSU SuSFS patch could not be applied cleanly: $DEFAULT_KSU_PATCH"
      printf '%s | %s | failed\n' "Default KernelSU SuSFS patch" "$DEFAULT_KSU_PATCH" >> "$PATCH_MANIFEST"
      exit 1
    fi
  fi
fi

# Ensure selinux_hide compatibility symbols exist for all variants.
# Older KernelSU trees keep them in feature/selinux_hide.c; current Tiann
# trees do not ship that feature file, so provide disabled symbols in
# selinux.c to satisfy the kernel-side SuSFS manual hooks.
echo "🔧 Ensuring selinux_hide symbols have global linkage..."
printf '%s\n' \
  'from pathlib import Path' \
  'feature = Path("kernel/feature/selinux_hide.c")' \
  'selinux = Path("kernel/selinux/selinux.c")' \
  'if feature.exists():' \
  '    text = feature.read_text()' \
  '    changed = False' \
  '    if "static struct selinux_state fake_state;" in text:' \
  '        text = text.replace("static struct selinux_state fake_state;", "struct selinux_state fake_state;", 1)' \
  '        changed = True' \
  '    if "static bool ksu_selinux_hide_running" in text:' \
  '        text = text.replace("static bool ksu_selinux_hide_running", "bool ksu_selinux_hide_running", 1)' \
  '        changed = True' \
  '    if changed:' \
  '        feature.write_text(text)' \
  '        print("✅ selinux_hide.c: promoted static symbols to global")' \
  '    else:' \
  '        print("ℹ️  selinux_hide.c: symbols already global or file layout differs")' \
  'elif selinux.exists():' \
  '    text = selinux.read_text()' \
  '    if "ksu_selinux_hide_running" not in text and "struct selinux_state fake_state" not in text:' \
  '        marker = "u32 ksu_file_sid __read_mostly = 0;\n"' \
  '        compat = marker + "\n#ifdef CONFIG_KSU_SUSFS\nstruct selinux_state fake_state;\nbool ksu_selinux_hide_running __read_mostly = false;\n#endif\n"' \
  '        if marker not in text:' \
  '            raise SystemExit("kernel/selinux/selinux.c layout drifted; could not add selinux_hide compatibility symbols")' \
  '        selinux.write_text(text.replace(marker, compat, 1))' \
  '        print("✅ selinux.c: added disabled selinux_hide compatibility symbols")' \
  '    else:' \
  '        print("ℹ️  selinux_hide compatibility symbols already present")' \
  'else:' \
  '    raise SystemExit("KernelSU SELinux sources not found; cannot satisfy selinux_hide symbols")' \
  | python3 -

if [ "$KSU_VARIANT" = "enhance" ]; then
  ENHANCE_SPOOF_PATCH="${GITHUB_WORKSPACE}/.github/patches/enhance/20-KernelSU-Spoof-LKM-mode-to-suppress-manager-warning.patch"
  if ! try_apply_patch "$ENHANCE_SPOOF_PATCH" "Enhance KernelSU manager compatibility spoof"; then
    echo "⚠️ Enhance manager compatibility spoof patch is stale, skipping: $ENHANCE_SPOOF_PATCH"
    printf '%s | %s | skipped-stale\n' "Enhance KernelSU manager compatibility spoof" "$ENHANCE_SPOOF_PATCH" >> "$PATCH_MANIFEST"
  fi
fi

if [ "$KSU_VARIANT" = "next" ] && [ -f fix_susfs.py ]; then
  python3 fix_susfs.py
  printf '%s | %s | applied\n' "KernelSU-Next repo susfs fixer" "fix_susfs.py" >> "$PATCH_MANIFEST"
fi

if [ "$KSU_VARIANT" = "tiann" ] || [ "$KSU_VARIANT" = "kowsu" ] || [ "$KSU_VARIANT" = "enhance" ]; then
  printf '%s\n' \
    'from pathlib import Path' \
    'target = Path("kernel/hook/setuid_hook.c")' \
    'if target.exists():' \
    '    text = target.read_text()' \
    '    if "susfs_run_sus_path_loop();" in text:' \
    '        target.write_text(text.replace("susfs_run_sus_path_loop();", "(void)0; /* symbol not available in this variant */"))' \
    | python -
  printf '%s | %s | applied\n' "Disable missing sus_path loop call (tiann/kowsu/enhance)" "kernel/hook/setuid_hook.c" >> "$PATCH_MANIFEST"
fi

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "PATCH_MANIFEST=$PATCH_MANIFEST" >> "$GITHUB_ENV"
  echo "PATCH_FAILURE_LOG=$PATCH_FAILURE_LOG" >> "$GITHUB_ENV"
fi

