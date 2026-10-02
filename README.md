# Eyeballs

An iPhone app for monitoring multiple Codex, Claude, Grok, Gemini CLI and GitHub Copilot accounts. Each connection has its own credentials, usage, settings and history, including multiple accounts from the same provider.

- Remaining usage by default, with optional used amounts.
- Up to four configurable rings per account: usage or time, with individual amount choices. Weekly time is enabled by default.
- Persistent compact bars, search, provider filters and account sorting.
- Account and multi-account widgets with selectable accounts, bars or rings, metrics and sorting. Dense rows show up to six accounts in a medium widget or twelve in a large widget, with account links.
- Provider logos, default brand colours and per-account colour overrides.
- Banked Codex reset counts and expiry dates when reported by the API.
- Local usage charts for 24 hours, 7, 30 or 90 days.
- Pull-to-refresh, timestamps, reset reminders and provider billing information where available.
- GitHub problem reports with an optional, reviewable debug bundle.

TestFlight **1.0 (7)** is available for internal testing, built from commit `58d4bda` and tagged `testflight/1.0-7`. It includes Copilot in addition to the Grok, widget and display fixes in builds 5–6. All source is public on the feature branches; [PR #1](https://github.com/dotdioscorea/eyeballs/pull/1) remains open and unmerged into `main`. TestFlight notes are in [RELEASE_NOTES.txt](RELEASE_NOTES.txt).

## Provider connections

Sign-in uses `ASWebAuthenticationSession` and the providers’ public native clients. Codex, Claude, Grok and Gemini use OAuth with PKCE; Copilot uses GitHub’s device authorization flow with an explicit one-time code. Normal sign-in can reuse browser sessions; “Use another account” starts a private session. Live usage must be verified before a connection can be saved.

| Provider | Usage endpoint | Identity |
| --- | --- | --- |
| Codex | `chatgpt.com/backend-api/wham/usage` | Signed RS256 OIDC identity |
| Claude | `api.anthropic.com/api/oauth/usage` | Authenticated profile API |
| Grok | `cli-chat-proxy.grok.com/v1/billing?format=credits` | Signed ES256 identity and access-token principal |
| Gemini CLI | `cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` | Authenticated Google user-info API |
| GitHub Copilot | `api.github.com/copilot_internal/user` | Authenticated GitHub user API |

Gemini reports Gemini CLI and Code Assist model quota buckets. It does not report the Gemini chat website's message allowance. Google must supply an existing Code Assist project for the account; the app does not create a Google account or enroll it into a new service. Unknown quota durations stay unknown. Google's system sign-in presentation and cancellation and the quota parser have been tested; a completed live Gemini authorization remains for the owner to test with their existing account.

Copilot requests only `read:user` and rejects credentials with repository scopes. It reports finite quota buckets and provider reset dates, skipping unlimited allowances. A completed device authorization returned a new `read:user` token; authenticated identity and usage requests both returned HTTP 200. The quota parser was checked against a live response; 63 unit tests and the native device-code presentation/cancellation check passed. The completed protocol authorization and simulator presentation are separate checks. Copilot is included in TestFlight build 7.

These are personal-use integrations with provider-controlled interfaces. Available metrics vary, and interfaces may change. Missing values remain unknown; reaching an expected reset never invents a new quota reading. There is no webpage scraping, embedded login browser, desktop collector or token import.

Protocol references: [Codex login](https://github.com/openai/codex/blob/main/codex-rs/login/src/server.rs), [Claude authentication](https://code.claude.com/docs/en/authentication), [Grok client configuration](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-login/src/config.rs), [Grok OAuth](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-login/src/oidc/protocol.rs), [Grok billing](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-shell/src/extensions/billing.rs), [Gemini Google OAuth](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/oauth2.ts), [Gemini quotas](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/server.ts), [GitHub device authorization](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow), [VS Code GitHub authentication client](https://github.com/microsoft/vscode/tree/main/extensions/github-authentication).

## Storage and updates

UUID-keyed tokens use Keychain `AfterFirstUnlockThisDeviceOnly`, with iCloud synchronization disabled. Account metadata and history use protected files in Application Support. Removing a connection removes its credentials, metadata, history and widget summary.

Widgets read an atomic App Group summary file. They receive names, workstreams, display preferences and cached usage, without emails, identities, notes or credentials. Unreadable account metadata preserves the last usable cache; unsupported or malformed individual summary entries are skipped without hiding other valid accounts. Entities and queries are compiled into both the app and widget extension so system configuration can resolve accounts in either process.

Usage is fetched when the app opens, every five minutes while it is active, on pull-to-refresh, and during background app refresh when iOS allows it. Widgets show cached readings; timestamp entries update their time rings. A widget does not keep the app running or guarantee extra provider fetches. [Apple controls widget update budgets](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date/) and background execution.

History records successful provider readings, retains up to 90 days and is capped at 12,000 samples per account. Charts split resets, unknown readings and gaps over two hours. Widget timelines never create history samples.

Diagnostics retain at most 100 local events for seven days. They record typed stages, providers, request categories, HTTP status codes, error categories and types of known usage fields. Parsing records identify the calculation used and classify readings as zero, partial, full or missing. Local connection UUIDs are replaced with bundle-local anonymous labels when exported, so multiple accounts and unsaved failed sign-ins can be distinguished. Debug exports also contain app/iOS versions and availability counts. They exclude tokens, passwords, OAuth state, HTTP bodies, URLs, account IDs, names, emails, workstreams and notes. Nothing is uploaded automatically; users review and attach the JSON file to a public GitHub issue themselves.

## Development

Requires Xcode, XcodeGen and an iOS 17+ simulator. Use `DEVELOPER_DIR` without changing the machine’s global developer directory.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export SIMULATOR_ID=<iPhone-simulator-UUID>
scripts/check.sh -parallel-testing-enabled NO
```

Simulator builds use local signing (`CODE_SIGN_IDENTITY=-`) so Keychain is available. `--ui-fixture` provides anonymous internal fixtures in a separate metadata directory in Debug builds. System widget tests use `--widget-fixture` to seed a disposable simulator’s normal account store, so a system-launched intent can resolve the same accounts; teardown clears only these labelled fixture records. Neither fixture has credentials, and both flags are absent from Release builds. There is no public preview mode.

Build 5 passed **56 unit tests and three distinct UI checks** on iOS 18.3.1 before packaging. UI checks verified account-picker selection in the Home Screen editor; persistent compact mode, display configuration and debug export; and a six-account widget retaining its rows after app termination, with a row tap opening the correct account and hiding the tab bar. The Grok parser was checked against a live billing response. Signed distribution app and widget entitlements were verified on the exact uploaded IPA.

Tests cover account isolation, identity verification, token rotation, OAuth callbacks, parser boundaries, existing-account migration, remaining/time metrics, sorting, widget cache privacy, entity resolution, history gaps/retention and debug-bundle exclusions. UI checks exercise provider-browser presentation and cancellation, display configuration, persistent compact mode and system widget selection. A browser-presentation test is distinct from a completed real account authorization.

## TestFlight

App and widget build numbers must match and increase for every upload. The archive is stamped with both targets’ capabilities before cloud signing. The exported IPA’s actual signatures must contain the shared App Group and distribution entitlements; `scripts/verify-release.py` checks this before the same IPA is uploaded. Apple signing credentials stay outside Git.

```sh
APPLE_TEAM_ID=<team-id> IOS_BUILD_NUMBER=<build-number> scripts/archive.sh
APPLE_TEAM_ID=<team-id> ASC_API_KEY_PATH=<p8-path> \
ASC_API_KEY_ID=<key-id> ASC_API_ISSUER_ID=<issuer-id> scripts/upload-testflight.sh
.venv/bin/python scripts/apple-connect.py set-test-notes --build <build-number>
.venv/bin/python scripts/apple-connect.py build-status --build <build-number>
```

Optional local Apple configuration belongs in ignored `.release/apple.json`. Verify processing is `VALID`, testing is `IN_BETA_TESTING`, and the intended tester is assigned before reporting availability. Exact uploaded source commits are tagged `testflight/1.0-N`.

Never commit credentials, provisioning profiles, archives, release configuration or real-account screenshots. The app icon is reproducible using `xcrun swift scripts/generate-icon.swift`.
