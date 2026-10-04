#!/usr/bin/env python3
"""Check capabilities in the actual signed IPA, before uploading it."""
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import zipfile

with tempfile.TemporaryDirectory() as directory:
    with zipfile.ZipFile(sys.argv[1]) as archive:
        archive.extractall(directory)
    root = pathlib.Path(directory)
    app = next((root / "Payload").glob("*.app"))
    bundles = [app, app / "PlugIns" / "RequotaWidgets.appex"]
    versions = []
    for bundle in bundles:
        signed = plistlib.loads(subprocess.check_output(
            ["codesign", "-d", "--entitlements", ":-", str(bundle)], stderr=subprocess.DEVNULL))
        if signed.get("com.apple.security.application-groups") != ["group.com.dotdioscorea.eyeballs"]:
            raise SystemExit(f"Missing signed App Group: {bundle.name}")
        if signed.get("get-task-allow") is not False:
            raise SystemExit(f"Not a distribution signature: {bundle.name}")
        info = plistlib.loads((bundle / "Info.plist").read_bytes())
        versions.append((info["CFBundleShortVersionString"], info["CFBundleVersion"]))
    if versions[0] != versions[1]:
        raise SystemExit("App and widget versions differ")
    print(f"Verified signed app and widget App Groups for {versions[0][0]} ({versions[0][1]})")
