#!/bin/zsh
# Native captures only; no App Store upload. Use a dedicated Requota Store simulator.
set -eu
cd "${0:A:h:h}"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
capture_device="${1:?Provide a dedicated simulator UUID}"
capture_family="${2:?Provide phone or ipad}"
[[ "$capture_family" == phone || "$capture_family" == ipad ]]
capture_run="artifacts/store-${capture_family}-$(date +%Y%m%d-%H%M%S)"
capture_folder="$capture_family"
[[ "$capture_family" != phone ]] || capture_folder=iphone
mkdir -p artifacts docs/app-store/captures/$capture_folder
xcrun simctl list devices available -j > "${capture_run}-devices.json"
python3 - "$capture_device" "${capture_run}-devices.json" <<'PY'
import json,sys
values=[d for group in json.load(open(sys.argv[2]))['devices'].values() for d in group]
device=next(d for d in values if d['udid']==sys.argv[1])
assert device['name'].startswith('Requota Store'), 'Use a dedicated Requota Store simulator'
assert device['state']=='Booted', 'Boot the dedicated simulator first'
PY
xcrun simctl status_bar "$capture_device" override --time '9:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
xcodegen generate
xcodebuild build -project Requota.xcodeproj -scheme Requota -destination "platform=iOS Simulator,id=$capture_device" -derivedDataPath DerivedData/StoreCapture ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- > "${capture_run}-build.log" 2>&1
xcrun simctl install "$capture_device" DerivedData/StoreCapture/Build/Products/Debug-iphonesimulator/Requota.app
# A capture does not need an automation runner installed on its Home Screen.
xcrun simctl uninstall "$capture_device" com.dotdioscorea.eyeballs.uitests.xctrunner 2>/dev/null || true
for capture_pair in 01-overview:tiles 03-compact:bars 04-charts:charts 05-activity:activity 06-rings:cards; do
    capture_name="${capture_pair%%:*}"
    capture_screen="${capture_pair#*:}"
    xcrun simctl launch --terminate-running-process "$capture_device" com.dotdioscorea.eyeballs --store-screenshots --store-screen "$capture_screen" --exit-demo-test
    # Initial state is selected before the first frame; allow fonts/layout to settle.
    sleep 3
    xcrun simctl io "$capture_device" screenshot "docs/app-store/captures/$capture_folder/$capture_name.png"
done
print "App captures saved. Capture the running Home Screen widget separately, then inspect every image before rendering the store artwork."
