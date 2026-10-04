# Requota 1.0 release preparation

Build **1.0 (19)** is available to the existing internal and external TestFlight groups. Apple approved external beta review. Its binary source is `e60b7f2aebd5eefe813942d6487c67040d2ec9c9`, tagged `testflight/1.0-19`. [PR #3](https://github.com/dotdioscorea/requota/pull/3) adds optional weekly activation. [PR #2](https://github.com/dotdioscorea/requota/pull/2), released in build 18, contains the Claude reset fix and source rename.

## App Store Connect

The [version draft](https://appstoreconnect.apple.com/apps/6818509879/distribution/ios/version/inflight) has build 19 selected and remains **Prepare for Submission**. No App Store review submission or public release was made. Release is set to **manual**.

- English UK title, subtitle, description, promotional text, keywords, support URL and copyright are saved.
- Six iPhone and five iPad screenshots finished processing, in the agreed order.
- Price is free in all 175 territories. All territories and future territories are selected, subject to Apple's distribution requirements.
- Categories are Utilities and Productivity. The age questionnaire produces 4+ with regional exceptions.
- The privacy policy URL is saved and the approved **Data Not Collected** responses are published.
- The existing trader declaration is retained. The signed package declares no non-exempt encryption.
- Reviewer contact details and [Demo access instructions](review-notes.txt) are saved. Private reviewer details remain outside this public repository.

Content Rights is saved as “Yes” on the owner’s confirmation of the necessary rights to third-party content.

## Validation

206 native unit checks passed out of 211 executed, with five opt-in live checks skipped. This includes 20 activation tests and a completed native Claude subscription request with identity/usage follow-up. Three native UI checks passed: provider preferences and explicit Claude permission; manual and automatic activation across three accounts with relaunch repeat prevention; and Claude available/spent reset panels. The [activation notes](../allowance-activation-2026-10-04.md) record the pending live unused-week check and the controlled-response validation. The earlier [reset handoff](../claude-reset-fix-2026-10-04.md) records the reset fix’s verification limits.

The exact uploaded IPA was checked for matching app/widget versions, distribution signatures, the shared App Group, both privacy manifests, background modes/task identifiers, the encryption declaration and exclusion of the Debug activation fixture. It was built with the iOS 26.5 SDK. See [the release record](../testflight-build-19.json) for the package hash and Apple status.

## Administration

`scripts/prepare-app-store.py` supports `metadata`, `screenshots`, `pricing`, `availability`, `select-build` and `verify`. Writes require `--apply` and an editable, unsubmitted version. Its API credentials are read from ignored `.release/apple.json`. It does not submit or release an App Store version.

App Store review submission and eventual manual release are separate actions.
