# Allowance activation

TestFlight **1.0 (19)** is available to the existing internal and external tester groups. Apple approved external beta testing. [PR #3](https://github.com/dotdioscorea/requota/pull/3) is merged into main; the binary source is `e60b7f2`, tagged `testflight/1.0-19`. See [the release record](testflight-build-19.json).

## Behaviour

- Settings → Allowance activation provides an off-by-default setting per provider. It applies independently to each saved account of that provider.
- Account pages provide a manual Start week action. It refreshes usage before deciding whether a request is needed.
- Automatic activation runs during app refreshes. It has no separate server or always-running widget process.
- Requests contain fixed short text and no tools, notes or usage history.
- Attempts are saved before sending. Interrupted or failed sends are not automatically retried within the week. Failures before sending can retry after a saved backoff; malformed model responses prompt a problem report. Observed usage followed by a new unused window can re-arm activation after an early reset.
- Completed requests and confirmed clock changes are recorded separately. HTTP 200 without a completed response is insufficient.
- Confirmation needs a new fixed deadline across later readings, for at least one minute on Codex and longer than one hour on Claude's hour-rounded deadlines. A pre-existing fixed deadline is not reported as a new start. Verification survives relaunch and does not send another request.
- Established weekly deadlines, exhausted or unknown allowances, unsupported billing plans, unreadable metadata and mismatched identities prevent consumption.

The shared policy handles eligibility, persistence, reporting and events. Codex and Claude have request adapters. Providers with scheduled allowances and standalone credit balances do not need an activation request. New first-use windows can use the same policy when their provider adapter is validated.

The other reported weekly allowances were checked against current provider documentation: [Kimi](https://www.kimi.ai/help/kimi-code/benefits) refreshes from the subscription date; [Devin](https://docs.devin.ai/admin/billing/self-serve#how-quotas-work) refreshes on a calendar basis; [Grok](https://docs.x.ai/grok/faq#usage--limits) refreshes on the schedule shown in its Usage settings. These do not need a request to start their week. Cursor and Copilot report billing/calendar periods, Gemini Code Assist reports daily quota deadlines, and Cline/Amp report credit balances. Perplexity's current response gives remaining counts without a weekly clock; the app does not invent one.

## Request validation

Authenticated protocol tests on 4 October 2026 used already-authorized local CLI connections. Both accounts had included allowance remaining. No reset was redeemed and no API key was created.

| Provider | Subscription request | Result |
| --- | --- | --- |
| Codex | Account-scoped `/backend-api/codex/models`, then `/backend-api/codex/responses`; visible Luna model, low reasoning, no tools, `store:false`, streamed response | HTTP 200; `response.completed`; 20 input and 5 output tokens |
| Claude | `/v1/models`, then `/v1/messages`; Haiku, 8 output-token limit, no tools | HTTP 200; `end_turn`; 11 input and 5 output tokens |

The Claude request also completed through the iOS simulator's native `URLSession` path, followed by a successful account identity and weekly-usage read. The native Codex send check was skipped by its allowance guard: the live account had reached 93% used. Its earlier protocol check above completed at 86% used. No guard was relaxed to obtain a passing test.

Claude's normal app connection retains `user:profile` only. Enabling activation requests `user:inference` explicitly, and reconnect/renewal preserves that optional grant. A read-only connection cannot send a message. The Codex adapter accepts only the existing native client registration; the separate public Sign in with ChatGPT inference flow is not substituted for it.

Codex's CLI implementation was checked against [OpenAI's source](https://github.com/openai/codex/blob/c2f7fe89d87ce853900d0b5cb1f5dc4863e44d73/codex-rs/codex-api/src/common.rs). OpenAI documents the first-request weekly clock after a purchased reset in its [reset guide](https://help.openai.com/en/articles/20001507-paid-weekly-work-and-codex-rate-limit-resets). That documentation does not establish the response shape for every kind of unused window.

## Field validation at the next unused week

The live request tests used active weeks. They prove authentication and minimal consumption, not that those requests start an unused weekly clock. The owner confirmed that a live unused week may not be available for up to a week; the beta uses controlled-response tests for that transition. The following live check remains pending:

1. Capture a redacted reading before its first request, identifying the weekly window and whether its deadline is absent or moving.
2. Send the request through the native adapter.
3. Verify that the requested weekly window now has a stable deadline, including a subsequent reading.
4. Confirm that a second refresh and app relaunch do not send another request.

A rounded 0% reading alone does not prove a week is unstarted. The current candidate policy additionally requires a reported clock field, a fresh reading, a qualifying personal plan and non-exhausted known windows; Codex must explicitly allow included usage. Missing or malformed fields are rejected. A full or absent deadline remains a candidate until the clock change is verified.

Private protocol artifacts remain under ignored `artifacts/`. Credentials stay outside Git. Local diagnostics include activation stages, endpoint categories, status and failure categories, candidate/clock status, deadline distance and observation age, without prompts, generated responses or credentials.

## Local checks

- Signed simulator build succeeded.
- Final native unit suite: 211 executed, 5 opt-in live checks skipped, 206 passed, no failures. This includes the native Claude request check and 20 activation policy/transport tests covering permission, plan and allowance checks, moving/fixed deadlines, tier changes, inactive Codex secondary windows, separate accounts, persistence, deletion and interrupted requests. The earlier native Claude live check also passed.
- Native UI: per-provider settings persist after relaunch and Claude's additional permission is presented explicitly. The existing available/spent Claude reset panel check also passed. A separate native UI test passed manual activation, automatic activation across three saved Codex accounts, and repeat prevention after relaunch. Its controlled provider fixture runs only in Debug simulator builds and is excluded from Release.
