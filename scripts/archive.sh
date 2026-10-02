#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
: "${IOS_BUILD_NUMBER:?Set IOS_BUILD_NUMBER to a unique increasing build number}"
: "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID}"
xcodegen generate
mkdir -p artifacts
xcodebuild -project Eyeballs.xcodeproj -scheme Eyeballs -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/Eyeballs.xcarchive \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CURRENT_PROJECT_VERSION="$IOS_BUILD_NUMBER" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO archive > artifacts/archive.log 2>&1 \
  || { tail -80 artifacts/archive.log; exit 1; }
python3 - <<'PY'
import os,pathlib,plistlib
app=pathlib.Path('build/Eyeballs.xcarchive/Products/Applications/Eyeballs.app')
for info in [app/'Info.plist',app/'PlugIns/EyeballsWidgets.appex/Info.plist']:
    data=plistlib.loads(info.read_bytes())
    if data['CFBundleVersion'] != os.environ['IOS_BUILD_NUMBER']:
        raise SystemExit(f'Incorrect archive build number in {info}')
print('Verified app and widget archive build numbers')
PY
tail -8 artifacts/archive.log
