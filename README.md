# Eyeballs

A native iPhone dashboard for multiple AI accounts, with usage rings, reset times, workstream labels and WidgetKit widgets. Multiple accounts from **the same provider** are independent connections, with separate credentials, refresh state and widget IDs.

Development build **1.0 (2)** was uploaded to TestFlight on 2 October 2026 and is available in the private Aaron group. The owner confirmed fresh Codex and Claude connections worked in that build. Build **1.0 (3)** removes an unsupported Grok OAuth scope that blocked authentication-code issuance; its fresh login → billing check remains pending. See [testing notes](RELEASE_NOTES.txt). Use **Take a look around** to try the dashboard with labelled sample accounts.

## Provider integration status

| Provider | Direct API reader | Native sign-in |
| --- | --- | --- |
| Codex | `GET https://chatgpt.com/backend-api/wham/usage`; existing CLI session returned HTTP 200 | Uses Codex's public native OAuth client, PKCE and verified OIDC identity. Replaces build 1's incompatible dynamic-registration grant. The owner confirmed a fresh app connection worked in build 2. |
| Claude | `GET https://api.anthropic.com/api/oauth/usage`; existing CLI session returned HTTP 200. The profile API also returned HTTP 200. | Native CLI-compatible OAuth/PKCE with `user:profile` scope. Account and organisation UUIDs come from the authenticated profile API. The owner confirmed a fresh app connection worked in build 2. |
| Grok | `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` | Native OAuth/PKCE with ES256 identity and access-token verification, personal/team isolation and the accounts site's CORS loopback callback. Requests the six identity/CLI proxy scopes from the official client, without its conversation/workspace scopes. Build 2's unsupported `billing:read` scope is removed in build 3. Fresh app login → billing verification is pending. |

These are personal-use integrations using the providers' public native CLI clients and direct usage endpoints. A successful API probe with an existing CLI session or a browser-presentation test does **not** establish a completed fresh app login. The app verifies live usage before enabling Save connection. A denied usage request is reported as an access failure, rather than an expired login. Saved connections attempt one token refresh after access denial; only terminal refresh failures request another sign-in.

Protocol references: [OpenAI's Codex login implementation](https://github.com/openai/codex/blob/main/codex-rs/login/src/server.rs), [Codex app-server account APIs](https://learn.chatgpt.com/docs/app-server#auth-endpoints), the locally installed official Claude Code executable's OAuth configuration and [Claude authentication documentation](https://code.claude.com/docs/en/authentication), [Grok's public-client configuration](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-login/src/config.rs), [Grok's OAuth protocol](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-login/src/oidc/protocol.rs), and [Grok's billing API implementation](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-shell/src/extensions/billing.rs).

There is no webpage scraping, embedded WebKit login, cookie capture, desktop collector or token import UI. Continue uses the normal system authentication session to reuse existing browser sign-ins where the provider permits. Use another account starts a private session when a different login is needed. Each saved connection stores its own credentials in Keychain. Claude requests profile access; Grok omits conversation/workspace writes and billing writes. Missing usage values stay unknown; a predicted reset never invents a zero reading. Preview accounts are labelled sample data and do not overwrite saved accounts or widgets.

## Build and test

Requires Xcode and XcodeGen. Use `DEVELOPER_DIR` to select Xcode without changing the machine's global developer directory.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
export SIMULATOR_ID=<booted-iPhone-simulator-UUID>
bash scripts/check.sh
```

Simulator builds must be signed locally (`CODE_SIGN_IDENTITY=-`). Unsigned simulator builds can display UI but Keychain operations fail with OSStatus -34018.

Build 3's code passed **35 unit tests and four distinct UI checks** on the local iOS 26.5 simulator. Checks cover two accounts per provider with the same email, persistence, reconnect identity, removal during an in-flight refresh, independent expiry, actual Keychain isolation, OAuth callback/PKCE/CORS checks, real RSA and P-256 signatures, bounded renewal after access denial, unsaved failed sign-ins, unknown quotas, quota-versus-billing periods and native navigation. Browser checks cover normal sessions for all three providers, a separate-account session for Codex and cancellation. The browser checks passed after the test correctly handled iOS's shared-session consent alert in SpringBoard. These checks do not claim completed real account authorisation; the owner's successful Codex and Claude logins are recorded separately above.

For optional read-only connectivity probes against existing local CLI sessions:

```sh
python3 -m venv .venv
.venv/bin/pip install -r requirements-dev.txt
.venv/bin/python scripts/probe-local-usage.py codex grok
```

The probe never refreshes or rewrites CLI credentials, copies them into the app, or prints tokens, emails or account IDs. Claude's probe is opt-in (`claude` argument); it demonstrates endpoint reachability only, not permission to integrate a mobile sign-in.

## Storage and widgets

Each connection has a UUID-keyed Keychain record with `AfterFirstUnlockThisDeviceOnly` accessibility and iCloud synchronization disabled. Metadata and cached readings are saved in a protected Application Support file. Widgets receive labels, workstreams and cached readings through `group.com.dotdioscorea.eyeballs`; email, account identity, notes and all credentials are excluded. Widget and background updates are scheduled by iOS, so refresh times are not guaranteed.

OAuth uses the system authentication session with fresh state and PKCE for every attempt and a loopback listener bound only to `127.0.0.1`. Codex and Grok validate signed OIDC identities, with issuer, audience, expiry and nonce checks. Codex pins RS256; Grok pins ES256 and also verifies its access-token principal. Claude verifies identity using its authenticated profile API. Grok callback CORS permits only `https://accounts.x.ai`; a preflight cannot consume a login. A returning login must match the selected connection's identity. API requests reject redirects and use ephemeral URL sessions without cookie storage or caching. Rotating refresh tokens are saved before reading usage, and stale in-flight reads cannot resurrect deleted or reconnected accounts.

## TestFlight releases

App Store Connect record: **6818509879**, store name **Eyeballs: AI Usage**. Bundle IDs: `com.dotdioscorea.eyeballs` and `com.dotdioscorea.eyeballs.widgets`. App group: `group.com.dotdioscorea.eyeballs`, registered and assigned to both targets. The private internal group automatically distributes uploaded builds. The app and extension are signed by Xcode during export using the existing Apple API key.

The Apple API key stays outside Git. Store optional local key configuration in ignored `.release/apple.json` with `key_id`, `issuer_id` and `key_path`; `scripts/apple-connect.py` can list apps, register bundle IDs, check a build's processing/testing state and update its TestFlight notes without logging credentials or tester email addresses.

To upload another development build, use a unique increasing build number:

```sh
APPLE_TEAM_ID=<team-id> IOS_BUILD_NUMBER=<unique-build-number> bash scripts/archive.sh
APPLE_TEAM_ID=<team-id> ASC_API_KEY_PATH=<existing-p8-file> \
ASC_API_KEY_ID=<key-id> ASC_API_ISSUER_ID=<issuer-id> bash scripts/upload-testflight.sh
.venv/bin/python scripts/apple-connect.py set-test-notes --build <build-number>
.venv/bin/python scripts/apple-connect.py build-status --build <build-number>
```

The export is restricted to internal TestFlight testing. Upload success alone is not tester availability: verify `processing_state` is `VALID`, `internal_testing_state` is `IN_BETA_TESTING`, and the intended tester is assigned. Uploaded app sources are tagged `testflight/1.0-1` and `testflight/1.0-2`.

Never commit API keys, session tokens, provisioning profiles, archives, local release configuration or real account screenshots. The icon is reproducible with `xcrun swift scripts/generate-icon.swift` and uses native geometric drawing.
