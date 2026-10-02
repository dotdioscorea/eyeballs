#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
: "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID}"
: "${ASC_API_KEY_PATH:?Set ASC_API_KEY_PATH}"
: "${ASC_API_KEY_ID:?Set ASC_API_KEY_ID}"
: "${ASC_API_ISSUER_ID:?Set ASC_API_ISSUER_ID}"
test -d build/Eyeballs.xcarchive || { echo 'Run scripts/archive.sh first'; exit 1; }
mkdir -p .release artifacts
python3 - <<'PY'
import os,plistlib,pathlib
options={'destination':'upload','method':'app-store-connect','signingStyle':'automatic','teamID':os.environ['APPLE_TEAM_ID'],'manageAppVersionAndBuildNumber':False,'testFlightInternalTestingOnly':True,'uploadSymbols':True}
pathlib.Path('.release/export.plist').write_bytes(plistlib.dumps(options))
PY
xcodebuild -exportArchive -archivePath build/Eyeballs.xcarchive \
  -exportPath build/TestFlight -exportOptionsPlist .release/export.plist \
  -allowProvisioningUpdates -authenticationKeyPath "$ASC_API_KEY_PATH" \
  -authenticationKeyID "$ASC_API_KEY_ID" -authenticationKeyIssuerID "$ASC_API_ISSUER_ID" \
  > artifacts/upload.log 2>&1 || { tail -80 artifacts/upload.log; exit 1; }
tail -8 artifacts/upload.log
