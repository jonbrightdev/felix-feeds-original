#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/setup.sh
swift test --package-path Core --scratch-path "${TMPDIR:-/tmp}/felix-feeds-original-core-tests"
npm --prefix Backend test
npm --prefix Backend run build
npm --prefix Backend run validate
xcodebuild -quiet -project FelixFeeds.xcodeproj -scheme FelixFeeds \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "${TMPDIR:-/tmp}/felix-feeds-original-build" \
  CODE_SIGNING_ALLOWED=NO build
