#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
: "${SIMULATOR_ID:?Set SIMULATOR_ID to a booted iPhone simulator UUID}"
xcodegen generate
mkdir -p artifacts
xcodebuild -project Eyeballs.xcodeproj -scheme Eyeballs \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  test "$@" > artifacts/check.log 2>&1 || { tail -80 artifacts/check.log; exit 1; }
tail -8 artifacts/check.log
