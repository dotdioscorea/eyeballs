# Requota

An iPhone app for monitoring multiple Codex, Claude, Grok, Gemini CLI, GitHub Copilot, Cursor, Cline and Kimi Code accounts. Each connection has its own credentials, usage, settings and history, including multiple accounts from the same provider.

- Remaining usage by default, with optional used amounts.
- Up to four configurable rings per account: usage or time, with individual amount choices. Weekly time is enabled by default.
- Cards, square tiles or compact bars; saved drag order, search, filters and metric sorting.
- Account and multi-account widgets with selectable accounts, bars or rings, metrics and sorting. Dense rows show up to six accounts in a medium widget or twelve in a large widget, with account links.
- Provider logos, default brand colours and per-account colour overrides.
- Banked Codex reset counts, reported expiry dates and first detection timestamps.
- Local line charts with tappable reset events, consumption heatmaps and account/metric comparisons.
- Recent percentage burn rates for 1h, 6h and 12h, with estimated time to zero.
- Display choices survive tier changes; known plan/allowance changes are recorded and start new analysis baselines.
- Pull-to-refresh, timestamps, configurable reset/expiry/unused-allowance reminders and an observed events log.
- GitHub problem reports with an optional, reviewable debug bundle.

TestFlight **1.0 (12)** is available for internal and external testing, built from commit `8f26aea` and tagged `testflight/1.0-12`. It adds Perplexity email-code sign-in, remaining search allowances, local count history and widget displays. Apple approved external testing, and the existing external tester group includes build 12. All source is public on the feature branch; [PR #1](https://github.com/dotdioscorea/eyeballs/pull/1) remains open and unmerged into `main`. See [testing notes](RELEASE_NOTES.txt) and [build 12 validation](docs/testflight-build-12.json).

## Provider connections

Browser sign-in uses `ASWebAuthenticationSession` and the providers’ public native clients. Perplexity uses a native passwordless email-code form and its own isolated session token. Codex, Claude, Grok and Gemini use OAuth with PKCE; Copilot uses GitHub’s device authorization flow with an explicit one-time code. Cursor uses its native browser handshake with PKCE and polling. Cline uses WorkOS device authorization. Kimi Code uses its device flow, with a choice of international or mainland China services. Normal sign-in can reuse browser sessions; “Use another account” starts a private session. Live usage must be verified before a connection can be saved.

| Provider | Usage endpoint | Identity |
| --- | --- | --- |
| Codex | `chatgpt.com/backend-api/wham/usage` | Signed RS256 OIDC identity |
| Claude | `api.anthropic.com/api/oauth/usage` | Authenticated profile API |
| Grok | `cli-chat-proxy.grok.com/v1/billing?format=credits` | Signed ES256 identity and access-token principal |
| Gemini CLI | `cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` | Authenticated Google user-info API |
| GitHub Copilot | `api.github.com/copilot_internal/user` | Authenticated GitHub user API |
| Cursor | `api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage` | Authenticated Cursor GetMe API |
| Cline | `api.cline.bot/api/v1/users/{id}/balance` | Authenticated Cline profile API |
| Kimi Code | `api.kimi.ai/coding/v1/usages` or `api.kimi.com/coding/v1/usages` | Authenticated Kimi Code `/me` API |
| Perplexity | `www.perplexity.ai/rest/rate-limit/status` | Authenticated Perplexity session and `/api/user` APIs |

Gemini reports Gemini CLI and Code Assist model quota buckets. It does not report the Gemini chat website's message allowance. Google must supply an existing Code Assist project for the account; the app does not create a Google account or enroll it into a new service. Unknown quota durations stay unknown. Google's system sign-in presentation and cancellation and the quota parser have been tested; a completed live Gemini authorization remains for the owner to test with their existing account.

Copilot requests only `read:user` and rejects credentials with repository scopes. It reports finite quota buckets and provider reset dates, skipping unlimited allowances. A completed device authorization returned a new `read:user` token; authenticated identity and usage requests both returned HTTP 200. The quota parser was checked against a live response; 63 unit tests and the native device-code presentation/cancellation check passed. The completed protocol authorization and simulator presentation are separate checks. Copilot is included in TestFlight build 7.

Cursor reports included, Auto and named-model usage percentages and the reported billing cycle. A free test account completed the native handshake; identity, usage and plan requests returned HTTP 200. The browser session expires after the provider’s reported token lifetime (currently 60 days) and requires sign-in again; the app does not create an API key. 65 unit tests and the native Cursor browser presentation/cancellation check passed. Cursor is included in build 8.

Cline uses the SDK's WorkOS device flow, native token registration and authenticated credit-balance endpoint. A free account completed browser authorization; registration, identity, balance, refresh and renewed identity/balance requests returned HTTP 200 with the same identity. The balance conversion was checked against Cline's dashboard and [credit controller](https://github.com/cline/cline/blob/main/apps/vscode/src/core/controller/account/getUserCredits.ts)/[display formatter](https://github.com/cline/cline/blob/main/apps/vscode/webview-ui/src/utils/format.ts): a REST balance of 500,000 is 0.5000 displayed credits. The app preserves zero and does not invent percentage quotas or reset dates.

Five Cline tests cover the live response's expiry format and balance units. The simulator loaded Cline's system sign-in page and cancelled without saving a connection; a completed native iPhone sign-in remains a separate manual check. Cline is included in TestFlight build 10.

Kimi Code, included in build 11, uses the [official SDK device flow and account APIs](https://github.com/MoonshotAI/kimi-code/tree/main/packages/oauth/src). Both regional services completed device authorization, refresh, profile and quota requests with HTTP 200. The tested Free account reported no Code quota; the app keeps that state distinct from 100% remaining. The parser supports the SDK's 5-hour, weekly and monthly ratios, older amount-based windows and extra-credit wallet/spending units. Paid-plan shapes are covered by fixtures; live paid-plan validation is outstanding. Native system-browser presentation and cancellation were checked separately from completed browser/API authorization.

Perplexity uses six-digit email codes, verifies the selected email and account identity, and renews its own provider-issued session before each refresh. Each connection has a separate Keychain record; no browser cookies are imported. The API reports remaining Pro searches, Research, Labs and Agentic research counts or explicit availability. Counts appear in cards, compact rows, tiles and widgets, and are stored in local history. The tested Free account reported no cap, reset date or billing period, so the app does not manufacture percentages or reset rings. Count history remains separate from percentage comparisons and heatmaps. Paid-plan readings remain to be tested live. See [protocol checks](docs/perplexity-protocol-validation-2026-10-03.json).

Claude account pages show reported extra spending, credit balances, named model/surface allowances and shares of weekly usage by app. Codex shows credit availability, spending caps, estimated local/cloud message ranges, model access and both periods of additional limits. Additional Codex metrics use stable feature IDs, with unambiguous migration of older saved rings and history. Estimates, usage shares and access flags do not establish actual token consumption or active credit charging. See [protocol validation](docs/provider-stats-research-2026-10-03.json).

These integrations use provider-controlled interfaces. Distribution permission is separate from technical access; see the [current permission investigation](docs/provider-integration-permissions-2026-10-02.md). Available metrics vary, and interfaces may change. Missing values remain unknown; reaching an expected reset never invents a new quota reading. There is no webpage scraping, embedded login browser, desktop collector or token import.

Protocol references: [Codex login](https://github.com/openai/codex/blob/main/codex-rs/login/src/server.rs), [Claude authentication](https://code.claude.com/docs/en/authentication), [Grok client configuration](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-login/src/config.rs), [Grok OAuth](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-login/src/oidc/protocol.rs), [Grok billing](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-shell/src/extensions/billing.rs), [Gemini Google OAuth](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/oauth2.ts), [Gemini quotas](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/server.ts), [GitHub device authorization](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow), [VS Code GitHub authentication client](https://github.com/microsoft/vscode/tree/main/extensions/github-authentication), [Cursor CLI authentication](https://cursor.com/docs/cli/reference/authentication).

The [app and widget design review](docs/design-review-2026-10-02.json) and [provider statistics review](docs/design-review-2026-10-03.json) record Opus 5.5’s findings and implementation decisions.

Claude refreshes its authenticated profile to read the current plan and rate-limit tier. A live Max 20× response was checked against the installed Claude client’s profile protocol. New quota fields become available in display settings; saved rings, amount choices, colours and names remain attached to the account if a downgrade removes a metric. Unavailable metrics show a dash and return when reported again. Known plan, cap, duration or amount-unit changes are recorded separately from resets and split history/forecast baselines. Unknown tier metadata never implies an upgrade or downgrade.

The app is now named Requota. Existing bundle IDs, Keychain services, App Groups, widget kinds and local data paths retain their original identifiers so updates preserve accounts, history and widget configuration.

## Storage and updates

The [privacy policy](https://dotdioscorea.github.io/eyeballs/) covers provider requests, local storage, widgets, optional reports and deletion. Its canonical source is [docs/privacy.html](docs/privacy.html).

UUID-keyed provider tokens, including Perplexity session tokens, use Keychain `AfterFirstUnlockThisDeviceOnly`, with iCloud synchronization disabled. Account metadata and history use protected files in Application Support. Removing a connection removes its credentials, metadata, history, events and widget summary.

Widgets read an atomic App Group summary file. They receive names, workstreams, display preferences and cached usage, without emails, identities, notes or credentials. Unreadable account metadata preserves the last usable cache; unsupported or malformed individual summary entries are skipped without hiding other valid accounts. Entities and queries are compiled into both the app and widget extension so system configuration can resolve accounts in either process.

Usage is fetched when the app opens, every five minutes while it is active, on pull-to-refresh, and during background app refresh when iOS allows it. Widgets show cached readings; timestamp entries update their time rings. A widget does not keep the app running or guarantee extra provider fetches. [Apple controls widget update budgets](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date/) and background execution.

History records successful provider readings, retains up to 90 days and is capped at 12,000 samples per account. Charts connect observed readings across gaps and reset drops, while unknown readings remain breaks. Long traces reduce rendering points while preserving endpoints and observed extrema; selection and analysis still use the full history. Unchanged reads keep a starting point and their latest timestamp. Heatmaps default to consumption between readings in the same allowance cycle. Reset drops are excluded; deltas crossing cell boundaries are assigned only when the interval is at most twenty minutes. Longer unobserved intervals are never spread across cells. Daily views use a 24-hour strip, weekly views use weekday/hour rows, and monthly views align to the local calendar. Quota level remains an option showing average reported levels. Unknown, observed zero and future cells have distinct appearances. Provider-reported amounts are shown only where available and comparisons keep different units separate. Widget timelines never create history samples. Burn-rate estimates use only the current allowance cycle within the selected 1h/6h/12h period, require recent readings and sufficient observed duration, and report when a reset precedes exhaustion. They estimate percentage points per hour, not token counts or credit charging.

Events retain up to 90 days, capped at 2,000 records. Early resets and banked reset use are inferred from large quota drops before the known deadline; unexplained reductions in banked counts are recorded as removals, not asserted to be used. Reset reminders use provider dates and the last reported allowance. Observed-event notifications depend on successful refreshes; iOS does not guarantee background refresh intervals. Parsing failures keep the previous reading and offer a report with an optional debug bundle.

Diagnostics retain at most 100 local events for seven days. They record typed stages, providers, request categories, HTTP status codes, error categories and types of known usage fields. Parsing records identify the calculation used and classify readings as zero, partial, full or missing. Local connection UUIDs are replaced with bundle-local anonymous labels when exported, so multiple accounts and unsaved failed sign-ins can be distinguished. Debug exports also contain app/iOS versions and availability counts. They exclude tokens, passwords, OAuth state, HTTP bodies, URLs, account IDs, names, emails, workstreams and notes. Nothing is uploaded automatically; users review and attach the JSON file to a public GitHub issue themselves.

Build 12 passed **130 unit tests, one opt-in native live networking check and four native UI checks** covering Perplexity email-form presentation/cancellation, count layouts/history, Demo restoration and a six-account widget containing a Perplexity count. Its exact IPA passed app/widget signing and shared App Group checks, and Apple reports it valid and available to internal and external testers. See [build 12 validation](docs/testflight-build-12.json).

Build 11 passed **118 unit tests and four native UI checks** in the final run: regional Kimi system sign-in/cancellation, Claude and Codex statistics, release Demo restoration and six-account widget configuration/persistence/deep links. Full-percentage rings and compact configuration also passed separate regression checks. Opus 5.5 reviewed the provider statistics screenshots. The exact uploaded IPA passed signature and App Group verification; Apple reports it valid and available to internal and external testers.

## Development

Requires Xcode, XcodeGen and an iOS 17+ simulator. Use `DEVELOPER_DIR` without changing the machine’s global developer directory.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export SIMULATOR_ID=<iPhone-simulator-UUID>
scripts/check.sh -parallel-testing-enabled NO
```

Simulator builds use local signing (`CODE_SIGN_IDENTITY=-`) so Keychain is available. `--ui-fixture` provides anonymous internal fixtures in a separate metadata directory in Debug builds. System widget tests use `--widget-fixture` to seed a disposable simulator’s normal account store, so a system-launched intent can resolve the same accounts; teardown clears only these labelled fixture records. Neither fixture has credentials, and both flags are absent from Release builds.

Settings → Demo is a release feature in build 9. It uses separate sample metadata, history, events, dashboard preferences and widget summaries, with no credentials or provider calls. Exit demo restores real connections and widget summaries. See [reviewer testing](docs/app-review-testing.md) for its scope and Apple’s access requirements.

Build 9 passed 77 unit tests and two distinct native UI checks covering persisted compact settings/debug export and Demo launch, tiles, history, events, reset simulation, relaunch and exit. The exact uploaded IPA passed signature and App Group verification; Apple reports it valid and in internal beta testing. Demo reviewer instructions were applied for build 11’s approved external review.

Build 5 passed **56 unit tests and three distinct UI checks** on iOS 18.3.1 before packaging. UI checks verified account-picker selection in the Home Screen editor; persistent compact mode, display configuration and debug export; and a six-account widget retaining its rows after app termination, with a row tap opening the correct account and hiding the tab bar. The Grok parser was checked against a live billing response. Signed distribution app and widget entitlements were verified on the exact uploaded IPA.

Tests cover account isolation, identity verification, token rotation, OAuth callbacks, parser boundaries, existing-account migration, remaining/time metrics, sorting, widget cache privacy, entity resolution, history gaps/retention and debug-bundle exclusions. UI checks exercise provider-browser presentation and cancellation, display configuration, persistent compact mode and system widget selection. A browser-presentation test is distinct from a completed real account authorization.

## TestFlight

App and widget build numbers must match and increase for every upload. The archive is stamped with both targets’ capabilities before cloud signing. The exported IPA’s actual signatures must contain the shared App Group and distribution entitlements; `scripts/verify-release.py` checks this before the same IPA is uploaded. Apple signing credentials stay outside Git. Exports allow external TestFlight review by default; set `TESTFLIGHT_INTERNAL_ONLY=1` only for a build that must remain internal. External invitations require Apple’s beta review approval.

```sh
APPLE_TEAM_ID=<team-id> IOS_BUILD_NUMBER=<build-number> scripts/archive.sh
APPLE_TEAM_ID=<team-id> ASC_API_KEY_PATH=<p8-path> \
ASC_API_KEY_ID=<key-id> ASC_API_ISSUER_ID=<issuer-id> scripts/upload-testflight.sh
.venv/bin/python scripts/apple-connect.py set-test-notes --build <build-number>
.venv/bin/python scripts/apple-connect.py build-status --build <build-number>
```

Optional local Apple configuration belongs in ignored `.release/apple.json`. Verify processing is `VALID`, testing is `IN_BETA_TESTING`, and the intended tester is assigned before reporting availability. Exact uploaded source commits are tagged `testflight/1.0-N`.

Never commit credentials, provisioning profiles, archives, release configuration or real-account screenshots. The app icon is reproducible using `xcrun swift scripts/generate-icon.swift`.
