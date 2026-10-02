# Eyeballs

A native iPhone dashboard for multiple AI accounts, with usage rings, reset times, workstream labels and WidgetKit widgets. Multiple accounts from **the same provider** are independent connections, with separate credentials, refresh state and widget IDs.

This is a development build. It has **not** been uploaded to TestFlight. The native UI, secure storage and direct API readers are implemented; provider login coverage is incomplete.

## Provider integration status

| Provider | Usage reader | Sign-in status |
| --- | --- | --- |
| Codex | Bearer-authenticated `GET https://chatgpt.com/backend-api/wham/usage`; live CLI-credential probe returned HTTP 200 | Native system-browser OAuth/PKCE prototype using OpenAI's dynamic registration flow. A fresh app-issued login and its permission to read this private quota endpoint have not been verified end to end. |
| Claude | Bearer-authenticated `GET https://api.anthropic.com/api/oauth/usage`; live CLI-credential probe returned HTTP 200 | Disabled: Anthropic explicitly disallows third-party Claude.ai sign-in and collecting subscription credentials. Requires an approved integration. |
| Grok | Bearer-authenticated `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` | Disabled until an approved app client is available. The existing local CLI token returned HTTP 401; no successful live response or fresh app login has been verified. |

An API reader working with an existing CLI token does **not** establish that the same reader works with credentials issued to an independent mobile app. OpenAI's Sign in with ChatGPT documentation primarily describes identity and plan-funded inference; it does not document permission to read the private Codex quota endpoint. That compatibility is a release blocker, not an assumed capability.

References: [OpenAI registration and sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in), [OpenAI accounts and sessions](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions), [Codex app-server account APIs](https://learn.chatgpt.com/docs/app-server#auth-endpoints), [Claude credential rules](https://code.claude.com/docs/en/legal-and-compliance#authentication-and-credential-use), [Grok Build authentication](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-pager/docs/user-guide/02-authentication.md).

No webpage scraping, embedded WebKit sign-in, cookie capture, desktop collector, token import UI or reuse of another app's public OAuth client ID is included. Missing provider values stay unknown; a predicted reset never invents a zero reading. Preview accounts are explicitly sample data and do not overwrite saved accounts or widget data.

## Build and test

Requires Xcode and XcodeGen. Use `DEVELOPER_DIR` to select Xcode without changing the machine's global developer directory.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
export SIMULATOR_ID=<booted-iPhone-simulator-UUID>
bash scripts/check.sh
```

Simulator builds must be signed locally (`CODE_SIGN_IDENTITY=-`). Unsigned simulator builds can display UI but Keychain operations fail with OSStatus -34018.

Tests cover two same-provider accounts with the same email, persistence, reconnection identity checks, removal during an in-flight refresh, independent expiry, actual Keychain record isolation, OAuth callback/PKCE checks, real RSA signature verification, unknown quota handling, quota-versus-billing periods and native UI navigation. UI presentation tests do not claim real account authorization.

For optional read-only connectivity probes against existing local CLI sessions:

```sh
python3 -m venv .venv
.venv/bin/pip install -r requirements-dev.txt
.venv/bin/python scripts/probe-local-usage.py codex grok
```

The probe never refreshes or rewrites CLI credentials, copies them into the app, or prints tokens, emails or account IDs. Claude's probe is opt-in (`claude` argument); it demonstrates endpoint reachability only, not permission to integrate a mobile sign-in.

## Storage and widgets

Each connection has a UUID-keyed Keychain record with `AfterFirstUnlockThisDeviceOnly` accessibility and iCloud synchronization disabled. Metadata and cached readings are saved in a protected Application Support file. Widgets receive labels, workstreams and cached readings through `group.com.dotdioscorea.eyeballs`; email, account identity, notes and all credentials are excluded. Widget and background updates are scheduled by iOS, so refresh times are not guaranteed.

The OAuth prototype uses the system authentication session with fresh state, nonce and PKCE for every attempt, a loopback listener bound only to `127.0.0.1`, RS256 signature verification and issuer/audience/expiry/nonce checks. A returning login must match the selected connection's identity. API requests reject redirects and use ephemeral URL sessions without cookie storage or caching. Rotating refresh tokens are saved before reading usage, and stale in-flight reads cannot resurrect deleted or reconnected accounts.

## Apple release preparation

Bundle IDs: `com.dotdioscorea.eyeballs` and `com.dotdioscorea.eyeballs.widgets`. App group: `group.com.dotdioscorea.eyeballs`. The Apple API key stays outside Git. Store optional local key configuration in ignored `.release/apple.json` with `key_id`, `issuer_id` and `key_path`; `scripts/apple-connect.py` can list apps or register these two bundle IDs with App Groups capability. The app group and App Store Connect app record must also be created on Apple's website.

Once provider authentication has been verified and registration is complete:

```sh
APPLE_TEAM_ID=<team-id> IOS_BUILD_NUMBER=<unique-build-number> bash scripts/archive.sh
APPLE_TEAM_ID=<team-id> ASC_API_KEY_PATH=<existing-p8-file> \
ASC_API_KEY_ID=<key-id> ASC_API_ISSUER_ID=<issuer-id> bash scripts/upload-testflight.sh
```

Never commit API keys, session tokens, provisioning profiles, archives, local release configuration or real account screenshots. The icon is reproducible with `xcrun swift scripts/generate-icon.swift` and uses native geometric drawing.
