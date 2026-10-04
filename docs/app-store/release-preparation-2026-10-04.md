# Requota 1.0 release preparation

Build **1.0 (20)** is available to the existing internal and external TestFlight groups. Apple approved external beta review. Its binary source is `6e5ef5c42b7ce50bcfb61aaec081ba6f91399e2e`, tagged `testflight/1.0-20`. [PR #5](https://github.com/dotdioscorea/requota/pull/5) makes weekly activation per account and compacts the controls. [PR #3](https://github.com/dotdioscorea/requota/pull/3), build 19, introduced activation; [PR #2](https://github.com/dotdioscorea/requota/pull/2), build 18, contains the Claude reset fix and source rename.

## App Store Connect

The [version draft](https://appstoreconnect.apple.com/apps/6818509879/distribution/ios/version/inflight) has build 20 selected and remains **Prepare for Submission**. No App Store review submission or public release was made. Release is set to **manual**.

- English UK title, subtitle, description, promotional text, keywords, support URL and copyright are saved.
- Six iPhone and five iPad screenshots finished processing, in the agreed order.
- Price is free in all 175 territories. All territories and future territories are selected, subject to Apple's distribution requirements.
- Categories are Utilities and Productivity. The age questionnaire produces 4+ with regional exceptions.
- The privacy policy URL is saved and the approved **Data Not Collected** responses are published.
- The existing trader declaration is retained. The signed package declares no non-exempt encryption.
- Reviewer contact details and [Demo access instructions](review-notes.txt) are saved. Private reviewer details remain outside this public repository.

Content Rights is saved as “Yes” on the owner’s confirmation of the necessary rights to third-party content.

## Validation

207 native unit checks passed out of 213 executed, with six opt-in live checks skipped. The 22 activation tests cover account isolation and migration, plus the existing policy and transport checks. Two native UI checks passed account preferences and Claude permission; side-by-side controls, the explanation popover, manual activation, selected-account automatic activation and relaunch repeat prevention. Screenshots were visually checked. Provider adapters and countdown verification are unchanged from build 19. The [activation notes](../allowance-activation-2026-10-04.md) record the pending live unused-week check; the earlier [reset handoff](../claude-reset-fix-2026-10-04.md) records the reset fix’s verification limits.

The exact uploaded IPA was checked for matching app/widget versions, distribution signatures, the shared App Group, both privacy manifests, background modes/task identifiers, the encryption declaration and exclusion of the Debug activation fixture. It was built with the iOS 26.5 SDK. See [the release record](../testflight-build-20.json) for the package hash and Apple status.

## Administration

`scripts/prepare-app-store.py` supports `metadata`, `screenshots`, `pricing`, `availability`, `select-build` and `verify`. Writes require `--apply` and an editable, unsubmitted version. Its API credentials are read from ignored `.release/apple.json`. It does not submit or release an App Store version.

App Store review submission and eventual manual release are separate actions.
