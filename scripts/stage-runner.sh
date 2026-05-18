#!/usr/bin/env bash
set -euo pipefail

cd "$HOME"
mkdir -p actions-runner
cd actions-runner

rel="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest)"
tag="$(echo "$rel" | jq -r .tag_name)"
ver="${tag#v}"
url="https://github.com/actions/runner/releases/download/${tag}/actions-runner-linux-x64-${ver}.tar.gz"
sha_url="https://github.com/actions/runner/releases/download/${tag}/actions-runner-linux-x64-${ver}.tar.gz.sha256"

echo "Latest runner: $tag"
echo "Tarball:       $url"

if [ ! -f "actions-runner-linux-x64-${ver}.tar.gz" ]; then
  curl -fL -o "actions-runner-linux-x64-${ver}.tar.gz" "$url"
fi

if curl -fsSL "$sha_url" -o runner.sha256 2>/dev/null; then
  expected="$(awk '{print $1}' runner.sha256)"
  actual="$(sha256sum "actions-runner-linux-x64-${ver}.tar.gz" | awk '{print $1}')"
  if [ "$expected" != "$actual" ]; then
    echo "SHA256 mismatch: expected=$expected actual=$actual" >&2
    exit 1
  fi
  echo "SHA256 OK ($actual)"
fi

tar xzf "actions-runner-linux-x64-${ver}.tar.gz"
echo "$ver" > .runner-version
ls -la
