#!/usr/bin/env bash
set -euo pipefail

# Trigger kernel-build.yml without gh CLI.
# Requires:
#   - GH_TOKEN or GITHUB_TOKEN with repo/workflow scope
# Optional env overrides:
#   - REPO (default: deepongi-labs/android14-6.1.162-common-2026-03)
#   - REF (default: main)
#   - KSU_VARIANT (default: all)
#   - DISABLE_SUSFS (default: false)
#   - FORCE_CLEAN_BUILD (default: false)
#   - ENABLE_TELEGRAM (default: false)
#   - CREATE_RELEASE (default: false)
#   - DRY_RUN_ONLY (default: false)

TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if [ -z "$TOKEN" ]; then
  echo "error: set GH_TOKEN or GITHUB_TOKEN before running this script." >&2
  exit 1
fi

REPO="${REPO:-deepongi-labs/android14-6.1.162-common-2026-03}"
REF="${REF:-main}"
KSU_VARIANT="${KSU_VARIANT:-all}"
DISABLE_SUSFS="${DISABLE_SUSFS:-false}"
FORCE_CLEAN_BUILD="${FORCE_CLEAN_BUILD:-false}"
ENABLE_TELEGRAM="${ENABLE_TELEGRAM:-false}"
CREATE_RELEASE="${CREATE_RELEASE:-false}"
DRY_RUN_ONLY="${DRY_RUN_ONLY:-false}"

API_URL="https://api.github.com/repos/${REPO}/actions/workflows/kernel-build.yml/dispatches"

payload=$(cat <<EOF
{
  "ref": "${REF}",
  "inputs": {
    "ksu_variant": "${KSU_VARIANT}",
    "disable_susfs": ${DISABLE_SUSFS},
    "force_clean_build": ${FORCE_CLEAN_BUILD},
    "enable_telegram": ${ENABLE_TELEGRAM},
    "create_release": ${CREATE_RELEASE},
    "dry_run_only": ${DRY_RUN_ONLY}
  }
}
EOF
)

curl -fsSL -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${TOKEN}" \
  "${API_URL}" \
  -d "${payload}"

echo
echo "✅ Dispatch created for ${REPO} on ref ${REF} (ksu_variant=${KSU_VARIANT})."
