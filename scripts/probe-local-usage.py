#!/usr/bin/env python3
"""Read-only connectivity check. Credentials stay in memory; output is redacted."""
import json
import pathlib
import subprocess
import requests

HOME_DIR = pathlib.Path.home()

def get_json(url, headers=None):
    response = requests.get(url, headers=headers or {}, timeout=20, allow_redirects=False)
    try:
        body = response.json()
    except ValueError:
        body = {}
    return response.status_code, body

def result(provider, status, body):
    output = {"provider": provider, "http_status": status}
    if status == 200:
        output["response_fields"] = sorted(body.keys()) if isinstance(body, dict) else []
        if provider == "codex":
            limits = body.get("rate_limit") or {}
            output["windows"] = {k: {f: v.get(f) for f in ("used_percent", "reset_at", "limit_window_seconds")} for k, v in limits.items() if isinstance(v, dict)}
        elif provider == "grok":
            config = body.get("config") or {}
            output["config_fields"] = sorted(config.keys())
            output["used_percent"] = config.get("creditUsagePercent")
            output["current_period"] = config.get("currentPeriod")
            output["billing_period_end"] = config.get("billingPeriodEnd")
        elif provider == "claude":
            output["windows"] = {k: {f: v.get(f) for f in ("utilization", "resets_at")} for k, v in body.items() if isinstance(v, dict) and k in ("five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet")}
    # Never log provider error bodies: they may echo request credentials.
    print(json.dumps(output))

def probe_codex():
    auth = json.loads((HOME_DIR / ".codex/auth.json").read_text())
    tokens = auth.get("tokens") or {}
    headers = {"Authorization": "Bearer " + tokens["access_token"], "Accept": "application/json", "User-Agent": "Requota/1.0"}
    if tokens.get("account_id"):
        headers["ChatGPT-Account-Id"] = tokens["account_id"]
    result("codex", *get_json("https://chatgpt.com/backend-api/wham/usage", headers))

def probe_grok():
    auth = json.loads((HOME_DIR / ".grok/auth.json").read_text())
    entry = next(v for k, v in auth.items() if k.startswith("https://auth.x.ai::"))
    result("grok", *get_json("https://cli-chat-proxy.grok.com/v1/billing?format=credits", {"Authorization": "Bearer " + entry["key"], "x-xai-token-auth": "xai-grok-cli", "Accept": "application/json", "User-Agent": "Requota/1.0"}))

def probe_claude():
    saved = subprocess.run(["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"], capture_output=True, check=True)
    auth = json.loads(saved.stdout)
    oauth = auth.get("claudeAiOauth") or {}
    result("claude", *get_json("https://api.anthropic.com/api/oauth/usage", {"Authorization": "Bearer " + oauth["accessToken"], "anthropic-beta": "oauth-2025-04-20", "Accept": "application/json", "User-Agent": "Requota/1.0"}))

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("providers", nargs="*", choices=["codex", "grok", "claude"], default=["codex", "grok"])
    args = parser.parse_args()
    for provider in args.providers:
        try:
            {"codex": probe_codex, "grok": probe_grok, "claude": probe_claude}[provider]()
        except Exception as error:
            print(json.dumps({"provider": provider, "error_type": type(error).__name__}))
