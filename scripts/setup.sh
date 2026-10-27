#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v xcodegen >/dev/null; then
  echo 'Install XcodeGen first: brew install xcodegen' >&2
  exit 1
fi
if [[ ! -f Config/Local.xcconfig ]]; then
  cp Config/Local.xcconfig.example Config/Local.xcconfig
fi
xcodegen generate
