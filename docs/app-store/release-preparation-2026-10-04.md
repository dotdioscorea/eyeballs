# Requota 1.0 release preparation

Build **1.0 (18)** is available to the existing internal and external TestFlight groups. Apple approved its external beta review. Its binary source is `afc88f322825184cbeb347bb9725c0fc3ce66109`, tagged `testflight/1.0-18`. [PR #2](https://github.com/dotdioscorea/requota/pull/2) contains the Claude reset fix and source rename.

## App Store Connect

The [version draft](https://appstoreconnect.apple.com/apps/6818509879/distribution/ios/version/inflight) has build 18 selected and remains **Prepare for Submission**. No App Store review submission or public release was made. Release is set to **manual**.

- English UK title, subtitle, description, promotional text, keywords, support URL and copyright are saved.
- Six iPhone and five iPad screenshots finished processing, in the agreed order.
- Price is free in all 175 territories. All territories and future territories are selected, subject to Apple's distribution requirements.
- Categories are Utilities and Productivity. The age questionnaire produces 4+ with regional exceptions.
- The privacy policy URL is saved and the approved **Data Not Collected** responses are published.
- The existing trader declaration is retained. The signed package declares no non-exempt encryption.
- Reviewer contact details and [Demo access instructions](review-notes.txt) are saved. Private reviewer details remain outside this public repository.

Content Rights is saved as “Yes” on the owner’s confirmation of the necessary rights to third-party content.

## Validation

186 unit tests passed, including a live native Claude identity/plan/usage/reset-inventory check; three other opt-in live tests were skipped. Three native simulator checks passed: Claude available/spent reset panels, Demo restoration, and six-account widget persistence/account links. [The reset handoff](../claude-reset-fix-2026-10-04.md) records the original gaps and verification limits.

The exact uploaded IPA was checked for matching app/widget versions, distribution signatures, the shared App Group, both privacy manifests, background modes/task identifiers and the encryption declaration. It was built with the iOS 26.5 SDK. See [the release record](../testflight-build-18.json) for the package hash and Apple status.

## Administration

`scripts/prepare-app-store.py` supports `metadata`, `screenshots`, `pricing`, `availability`, `select-build` and `verify`. Writes require `--apply` and an editable, unsubmitted version. Its API credentials are read from ignored `.release/apple.json`. It does not submit or release an App Store version.

App Store review submission and eventual manual release are separate actions.
