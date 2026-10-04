#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
: "${IOS_BUILD_NUMBER:?Set IOS_BUILD_NUMBER to a unique increasing build number}"
: "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID}"
xcodegen generate
mkdir -p artifacts
xcodebuild -project Requota.xcodeproj -scheme Requota -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/Requota.xcarchive \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CURRENT_PROJECT_VERSION="$IOS_BUILD_NUMBER" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO archive > artifacts/archive.log 2>&1 \
  || { tail -80 artifacts/archive.log; exit 1; }
# The export step reads capabilities from the archive's code signature. An
# unsigned archive loses App Groups during cloud signing, despite the source
# entitlement file. Stamp both binaries with their requested entitlements first.
APP_PATH=build/Requota.xcarchive/Products/Applications/Requota.app
codesign --force --sign - --entitlements App/RequotaWidgets/RequotaWidgets.entitlements \
  --generate-entitlement-der "$APP_PATH/PlugIns/RequotaWidgets.appex"
codesign --force --sign - --entitlements App/Requota/Requota.entitlements \
  --generate-entitlement-der "$APP_PATH"
python3 - <<'PY'
import os,pathlib,plistlib,subprocess
app=pathlib.Path('build/Requota.xcarchive/Products/Applications/Requota.app')
for info in [app/'Info.plist',app/'PlugIns/RequotaWidgets.appex/Info.plist']:
    data=plistlib.loads(info.read_bytes())
    if data['CFBundleVersion'] != os.environ['IOS_BUILD_NUMBER']:
        raise SystemExit(f'Incorrect archive build number in {info}')
    signed = plistlib.loads(subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(info.parent)], stderr=subprocess.DEVNULL))
    if signed.get('com.apple.security.application-groups') != ['group.com.dotdioscorea.eyeballs']:
        raise SystemExit(f'Missing shared App Group in {info.parent}')
print('Verified app and widget archive build numbers')
PY
tail -8 artifacts/archive.log
