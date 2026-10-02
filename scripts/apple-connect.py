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
        assert path.startswith("/v1/")
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
    parser.add_argument("action", choices=["list-apps", "register-identifiers"])
    parser.add_argument("--config", default=".release/apple.json")
    args = parser.parse_args()
    config = json.loads(pathlib.Path(args.config).read_text())
    api = AppleConnect(config)
    if args.action == "list-apps":
        values = api.request("GET", "/v1/apps", params={"limit": 20})["data"]
        print(json.dumps([{k: v for k, v in {"id": item["id"], "name": item["attributes"]["name"], "bundle_id": item["attributes"]["bundleId"]}.items()} for item in values], indent=2))
    else:
        values = [api.register_identifier("com.dotdioscorea.eyeballs", "Eyeballs"), api.register_identifier("com.dotdioscorea.eyeballs.widgets", "Eyeballs Widgets")]
        print(json.dumps(values, indent=2))
        print("Create the shared app group and app record in Apple's website before uploading.")

if __name__ == "__main__":
    main()
