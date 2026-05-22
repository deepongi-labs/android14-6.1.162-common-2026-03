#!/usr/bin/env python3
"""
Patch SUSFS namespace declaration mismatch in fs/namespace.c.

Fixes:
    extern bool susfs_is_sdcard_android_data_decrypted __read_mostly;

to:
    extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;

Why:
    fs/namespace.c uses static_branch_unlikely(&susfs_is_sdcard_android_data_not_decrypted),
    which requires a jump-label static key, not a bool.
"""

from __future__ import annotations

import argparse
import difflib
import shutil
import sys
from pathlib import Path


BAD_LINE = "extern bool susfs_is_sdcard_android_data_decrypted __read_mostly;"
GOOD_LINE = "extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;"


def patch_text(text: str) -> tuple[str, bool, str]:
    """
    Return (new_text, changed, mode)
    mode is one of: exact_block, line_replace, already_patched, not_found
    """
    if GOOD_LINE in text and BAD_LINE not in text:
        return text, False, "already_patched"

    # Preferred: replace only within the SUSFS block if present
    block_old = (
        "#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
        "extern bool susfs_is_current_ksu_domain(void);\n"
        f"{BAD_LINE}\n"
        "\n"
        "#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */\n"
    )
    block_new = (
        "#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
        "extern bool susfs_is_current_ksu_domain(void);\n"
        f"{GOOD_LINE}\n"
        "\n"
        "#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */\n"
    )

    if block_old in text:
        return text.replace(block_old, block_new, 1), True, "exact_block"

    if BAD_LINE in text:
        return text.replace(BAD_LINE, GOOD_LINE, 1), True, "line_replace"

    return text, False, "not_found"


def unified_diff(old: str, new: str, path: str) -> str:
    return "".join(
        difflib.unified_diff(
            old.splitlines(keepends=True),
            new.splitlines(keepends=True),
            fromfile=f"a/{path}",
            tofile=f"b/{path}",
        )
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Patch fs/namespace.c to use the correct SUSFS static key declaration."
    )
    parser.add_argument(
        "target",
        nargs="?",
        default="fs/namespace.c",
        help="Path to namespace.c (default: fs/namespace.c)",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Check whether the file needs patching; do not modify.",
    )
    parser.add_argument(
        "--diff",
        action="store_true",
        help="Print a unified diff.",
    )
    parser.add_argument(
        "--no-backup",
        action="store_true",
        help="Do not create a .bak backup before modifying.",
    )
    args = parser.parse_args()

    path = Path(args.target)

    if not path.exists():
        print(f"error: file not found: {path}", file=sys.stderr)
        return 2

    original = path.read_text(encoding="utf-8")
    patched, changed, mode = patch_text(original)

    if mode == "already_patched":
        print(f"{path}: already patched")
        return 0

    if mode == "not_found":
        print(f"{path}: target declaration not found", file=sys.stderr)
        return 1

    if args.diff:
        diff = unified_diff(original, patched, str(path))
        if diff:
            print(diff, end="")

    if args.check:
        print(f"{path}: needs patch ({mode})")
        return 1

    if not args.no_backup:
        backup = path.with_suffix(path.suffix + ".bak")
        shutil.copy2(path, backup)
        print(f"backup: {backup}")

    path.write_text(patched, encoding="utf-8")
    print(f"patched: {path} ({mode})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
