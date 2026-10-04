# Claude banked resets

Build 17 did not request or parse Claude’s banked reset inventory. Early-reset inference also required the next usage reading to be at most 1%, missing resets followed by resumed use. The earlier generic reset tests did not cover Claude’s live response or this polling interval.

The usage request now opts into `cedar_ember=1`. A read-only comparison with the installed Claude Code 2.1.287 OAuth session confirmed that a plain request returns a null reset block, the opt-in query with a generic product User-Agent returns `ineligible_reason: surface`, and Claude Code’s client prefix with the Requota product identifier returns eligible grant data. The tested grant reported one total reset, none remaining, and an expiry of 22 October 2026. No reset was redeemed during testing.

Grant counts, expiry, availability and affected limits are parsed alongside usage. Redemption handles and provider-supplied labels are not persisted. Spent grants are retained as the comparison baseline. Unavailable or malformed inventory remains unknown and preserves the last known inventory with its check time. A count decrease before expiry records banked use even if usage has already resumed; pauses, expiry and plan changes are covered separately. Substantial usage drops can also produce a labelled inferred early reset without grant evidence.

Debug bundle schema 5 includes the reset-response category, before/after allowance percentages and reset counts, detected event kinds, and inventory age. It excludes credentials and grant handles. No historical redemption time is invented when the first observation already shows a spent grant.

## Verification

Regression coverage includes the observed grant shape, known-zero versus unavailable inventory, malformed counts/dates, waiting grants, expiry, pauses, resumed use, high burn after use, duplicate suppression, tier changes, multiple Claude accounts and persistence after relaunch. The optional live test calls the app’s actual native usage client and checks its profile identity, plan, weekly quota and reset inventory.

Provider features need provider-specific response coverage; generic event tests alone do not establish live support. The live Claude check establishes this account and response shape, rather than every subscription tier.
