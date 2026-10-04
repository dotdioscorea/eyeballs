#!/usr/bin/env python3
"""App Store Connect administration using an existing API key. Never logs the JWT."""
import argparse
import base64
import json
import os
import pathlib
import time

import requests
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils

def encoded(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

def token(config):
    header = encoded(json.dumps({"alg": "ES256", "kid": config["key_id"], "typ": "JWT"}, separators=(",", ":")).encode())
    payload = encoded(json.dumps({"iss": config["issuer_id"], "iat": int(time.time()), "exp": int(time.time()) + 300, "aud": "appstoreconnect-v1"}, separators=(",", ":")).encode())
    message = (header + "." + payload).encode()
    key = serialization.load_pem_private_key(pathlib.Path(config["key_path"]).read_bytes(), password=None)
    r, s = utils.decode_dss_signature(key.sign(message, ec.ECDSA(hashes.SHA256())))
    return message.decode() + "." + encoded(r.to_bytes(32, "big") + s.to_bytes(32, "big"))

class AppleConnect:
    def __init__(self, config):
        self.authorization = token(config)
    def request(self, method, path, **kwargs):
        assert path.startswith(("/v1/", "/v2/"))
        response = requests.request(method, "https://api.appstoreconnect.apple.com" + path,
                                    headers={"Authorization": "Bearer " + self.authorization}, timeout=30, allow_redirects=False, **kwargs)
        if response.status_code >= 300:
            # Never print server bodies which might echo headers or credentials.
            raise RuntimeError(f"App Store Connect returned HTTP {response.status_code} for {method} {path}")
        return response.json() if response.content else {}
    def register_identifier(self, identifier, name):
        existing = self.request("GET", "/v1/bundleIds", params={"filter[identifier]": identifier})["data"]
        if existing:
            bundle = existing[0]
        else:
            bundle = self.request("POST", "/v1/bundleIds", json={"data": {"type": "bundleIds", "attributes": {"identifier": identifier, "name": name, "platform": "IOS"}}})["data"]
        capabilities = self.request("GET", f"/v1/bundleIds/{bundle['id']}/bundleIdCapabilities")["data"]
        if not any(c["attributes"]["capabilityType"] == "APP_GROUPS" for c in capabilities):
            self.request("POST", "/v1/bundleIdCapabilities", json={"data": {"type": "bundleIdCapabilities", "attributes": {"capabilityType": "APP_GROUPS"}, "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle["id"]}}}}})
        return {"identifier": identifier, "id": bundle["id"], "app_groups_capability": True}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["list-apps", "register-identifiers", "build-status", "set-test-notes"])
    parser.add_argument("--config", default=".release/apple.json")
    parser.add_argument("--app-id", default="6818509879")
    parser.add_argument("--build", default="1")
    parser.add_argument("--notes", default="RELEASE_NOTES.txt")
    args = parser.parse_args()
    config = json.loads(pathlib.Path(args.config).read_text())
    api = AppleConnect(config)
    if args.action == "list-apps":
        values = api.request("GET", "/v1/apps", params={"limit": 20})["data"]
        print(json.dumps([{k: v for k, v in {"id": item["id"], "name": item["attributes"]["name"], "bundle_id": item["attributes"]["bundleId"]}.items()} for item in values], indent=2))
    elif args.action == "register-identifiers":
        values = [api.register_identifier("com.dotdioscorea.eyeballs", "Requota"), api.register_identifier("com.dotdioscorea.eyeballs.widgets", "Requota Widgets")]
        print(json.dumps(values, indent=2))
        print("Create the shared app group and app record in Apple's website before uploading.")
    else:
        app = api.request("GET", f"/v1/apps/{args.app_id}")["data"]
        if app["attributes"]["bundleId"] != "com.dotdioscorea.eyeballs":
            raise RuntimeError("The selected app is not Requota")
        response = api.request("GET", "/v1/builds", params={"filter[app]": args.app_id, "filter[version]": args.build, "include": "buildBetaDetail,preReleaseVersion"})
        builds = response["data"]
        if len(builds) != 1:
            raise RuntimeError(f"Expected one uploaded build {args.build}; found {len(builds)}")
        build = builds[0]
        if args.action == "set-test-notes":
            notes = pathlib.Path(args.notes).read_text().strip()
            if not notes or len(notes) > 4000:
                raise RuntimeError("Testing notes must contain 1–4000 characters")
            localizations = api.request("GET", f"/v1/builds/{build['id']}/betaBuildLocalizations")["data"]
            existing = next((item for item in localizations if item["attributes"]["locale"] == "en-GB"), None)
            if existing:
                api.request("PATCH", f"/v1/betaBuildLocalizations/{existing['id']}", json={"data": {"type": "betaBuildLocalizations", "id": existing["id"], "attributes": {"whatsNew": notes}}})
            else:
                api.request("POST", "/v1/betaBuildLocalizations", json={"data": {"type": "betaBuildLocalizations", "attributes": {"locale": "en-GB", "whatsNew": notes}, "relationships": {"build": {"data": {"type": "builds", "id": build["id"]}}}}})
            print("Saved TestFlight testing notes")
        details = next((item["attributes"] for item in response.get("included", []) if item["type"] == "buildBetaDetails"), {})
        version = next((item["attributes"].get("version") for item in response.get("included", []) if item["type"] == "preReleaseVersions"), None)
        groups = api.request("GET", f"/v1/apps/{args.app_id}/betaGroups")["data"]
        testers = sum(len(api.request("GET", f"/v1/betaGroups/{g['id']}/betaTesters")["data"]) for g in groups if g["attributes"]["isInternalGroup"])
        print(json.dumps({"app": app["attributes"]["name"], "version": version, "build": build["attributes"]["version"], "processing_state": build["attributes"]["processingState"], "internal_testing_state": details.get("internalBuildState"), "internal_tester_assignments": testers}, indent=2))

if __name__ == "__main__":
    main()
