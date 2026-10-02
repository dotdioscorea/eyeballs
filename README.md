# Eyeballs

An iPhone app for monitoring multiple Codex, Claude and Grok accounts. Each connection has its own credentials, usage, settings and history, including multiple accounts from the same provider.

- Remaining usage by default, with optional used amounts.
- Up to four configurable rings per account: usage or time, with individual amount choices.
- Persistent compact bars, search, provider filters and account sorting.
- Account and multi-account widgets with selectable accounts, bars or rings, metrics and sorting.
- Local usage charts for 24 hours, 7, 30 or 90 days.
- Pull-to-refresh, timestamps, reset reminders and provider billing information where available.
- GitHub problem reports with an optional, reviewable debug bundle.

TestFlight **1.0 (4)** is available for internal testing, built from commit `45231b9` and tagged `testflight/1.0-4`. The dashboard, widget and history changes are on `feature/configurable-dashboard-widgets`, with [PR #1](https://github.com/dotdioscorea/eyeballs/pull/1) open and unmerged into `main`. The owner confirmed fresh Codex, Claude and Grok sign-ins in build 3; provider authorization logic is unchanged in build 4. TestFlight release notes are in [RELEASE_NOTES.txt](RELEASE_NOTES.txt).

## Provider connections

Sign-in uses `ASWebAuthenticationSession`, OAuth with PKCE, and the providers’ public native CLI clients. Normal sign-in can reuse browser sessions; “Use another account” starts a private session. Live usage must be verified before a connection can be saved.

| Provider | Usage endpoint | Identity |
| --- | --- | --- |
| Codex | `chatgpt.com/backend-api/wham/usage` | Signed RS256 OIDC identity |
| Claude | `api.anthropic.com/api/oauth/usage` | Authenticated profile API |
| Grok | `cli-chat-proxy.grok.com/v1/billing?format=credits` | Signed ES256 identity and access-token principal |

These are personal-use integrations with provider-controlled interfaces. Available metrics vary, and interfaces may change. Missing values remain unknown; reaching an expected reset never invents a new quota reading. There is no webpage scraping, embedded login browser, desktop collector or token import.

Protocol references: [Codex login](https://github.com/openai/codex/blob/main/codex-rs/login/src/server.rs), [Claude authentication](https://code.claude.com/docs/en/authentication), [Grok client configuration](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-login/src/config.rs), [Grok OAuth](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-login/src/oidc/protocol.rs), [Grok billing](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-shell/src/extensions/billing.rs).

## Storage and updates

UUID-keyed tokens use Keychain `AfterFirstUnlockThisDeviceOnly`, with iCloud synchronization disabled. Account metadata and history use protected files in Application Support. Removing a connection removes its credentials, metadata, history and widget summary.

Widgets read an atomic App Group summary file. They receive names, workstreams, display preferences and cached usage, without emails, identities, notes or credentials. Entities and queries are compiled into both the app and widget extension so system configuration can resolve accounts in either process.

Usage is fetched when the app opens, every five minutes while it is active, on pull-to-refresh, and during background app refresh when iOS allows it. Widgets show cached readings; timestamp entries update their time rings. A widget does not keep the app running or guarantee extra provider fetches. [Apple controls widget update budgets](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date/) and background execution.

History records successful provider readings, retains up to 90 days and is capped at 12,000 samples per account. Charts split resets, unknown readings and gaps over two hours. Widget timelines never create history samples.

Diagnostics retain at most 100 local events for seven days. They accept only typed sign-in stages, provider names, HTTP status codes and error categories. Debug exports also contain app/iOS versions and anonymous availability counts. They exclude tokens, passwords, OAuth state, HTTP bodies, URLs, account IDs, names, emails, workstreams and notes. Nothing is uploaded automatically; users review and attach the JSON file to a public GitHub issue themselves.

## Development

Requires Xcode, XcodeGen and an iOS 17+ simulator. Use `DEVELOPER_DIR` without changing the machine’s global developer directory.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export SIMULATOR_ID=<iPhone-simulator-UUID>
scripts/check.sh -parallel-testing-enabled NO
```

Simulator builds use local signing (`CODE_SIGN_IDENTITY=-`) so Keychain is available. `--ui-fixture` provides anonymous internal fixtures in a separate metadata directory in Debug builds. System widget tests use `--widget-fixture` to seed a disposable simulator’s normal account store, so a system-launched intent can resolve the same accounts; teardown clears only these labelled fixture records. Neither fixture has credentials, and both flags are absent from Release builds. There is no public preview mode.

The feature passed **49 unit tests and four distinct UI checks** on iOS 18.3.1 before packaging. UI checks verified account-picker selection in the Home Screen editor, a two-account widget with a layout change, persistent compact mode/display configuration/debug export, and all provider connection screens/cancellation.

Tests cover account isolation, identity verification, token rotation, OAuth callbacks, parser boundaries, existing-account migration, remaining/time metrics, sorting, widget cache privacy, entity resolution, history gaps/retention and debug-bundle exclusions. UI checks exercise provider-browser presentation and cancellation, display configuration, persistent compact mode and system widget selection. A browser-presentation test is distinct from a completed real account authorization.

## TestFlight

App and widget build numbers must match and increase for every upload. Apple signing credentials stay outside Git.

```sh
APPLE_TEAM_ID=<team-id> IOS_BUILD_NUMBER=<build-number> scripts/archive.sh
APPLE_TEAM_ID=<team-id> ASC_API_KEY_PATH=<p8-path> \
ASC_API_KEY_ID=<key-id> ASC_API_ISSUER_ID=<issuer-id> scripts/upload-testflight.sh
.venv/bin/python scripts/apple-connect.py set-test-notes --build <build-number>
.venv/bin/python scripts/apple-connect.py build-status --build <build-number>
```

Optional local Apple configuration belongs in ignored `.release/apple.json`. Verify processing is `VALID`, testing is `IN_BETA_TESTING`, and the intended tester is assigned before reporting availability. Exact uploaded source commits are tagged `testflight/1.0-N`.

Never commit credentials, provisioning profiles, archives, release configuration or real-account screenshots. The app icon is reproducible using `xcrun swift scripts/generate-icon.swift`.
