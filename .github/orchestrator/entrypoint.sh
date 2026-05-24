#!/bin/bash
set -e

# GitHub Actions Runner Entrypoint Script
# Configures and starts a self-hosted runner in a Docker container

# Required environment variables
: "${RUNNER_NAME:?RUNNER_NAME is required}"
: "${RUNNER_TOKEN:?RUNNER_TOKEN is required}"
: "${RUNNER_REPOSITORY_URL:?RUNNER_REPOSITORY_URL is required}"

# Optional environment variables
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,x64,docker}"
RUNNER_WORKDIR="${RUNNER_WORKDIR:-/work}"
RUNNER_GROUP="${RUNNER_GROUP:-default}"

echo "=========================================="
echo "GitHub Actions Runner Configuration"
echo "=========================================="
echo "Runner Name: ${RUNNER_NAME}"
echo "Repository: ${RUNNER_REPOSITORY_URL}"
echo "Labels: ${RUNNER_LABELS}"
echo "Work Directory: ${RUNNER_WORKDIR}"
echo "=========================================="

cd /home/deepongi/actions-runner

# Configure the runner
echo "Configuring runner..."
./config.sh \
    --url "${RUNNER_REPOSITORY_URL}" \
    --token "${RUNNER_TOKEN}" \
    --name "${RUNNER_NAME}" \
    --labels "${RUNNER_LABELS}" \
    --work "${RUNNER_WORKDIR}" \
    --runnergroup "${RUNNER_GROUP}" \
    --unattended \
    --replace

# Cleanup function
cleanup() {
    echo "Removing runner..."
    ./config.sh remove --token "${RUNNER_TOKEN}" || true
}

# Register cleanup on exit
trap cleanup EXIT INT TERM

# Start the runner
echo "Starting runner..."
./run.sh
