#!/bin/bash
# Test the orchestrator without systemd

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# Load environment
set -a
source orchestrator.env
set +a

# Run orchestrator
python3 runner-orchestrator.py
