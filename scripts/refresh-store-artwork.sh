#!/bin/zsh
set -eu
cd "${0:A:h:h}"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
mkdir -p artifacts
xcrun swiftc scripts/render-store-screenshots.swift -o artifacts/render-store-screenshots
artifacts/render-store-screenshots docs/app-store/captures/iphone docs/app-store/assets
artifacts/render-store-screenshots docs/app-store/captures/ipad docs/app-store/assets/ipad ipad
python3 scripts/prepare-store-listing.py
python3 scripts/prepare-store-listing.py --check
