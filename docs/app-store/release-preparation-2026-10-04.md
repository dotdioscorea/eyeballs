# Requota 1.0 release preparation

Build **1.0 (17)** is available to the existing internal and external TestFlight groups. Apple approved its external beta review. The source is merge commit `82ee4dda6763c3fd53771ce9d46fb39136f91410`, tagged `testflight/1.0-17`; [PR #1](https://github.com/dotdioscorea/eyeballs/pull/1) is merged into `main`.

## App Store Connect

The [version draft](https://appstoreconnect.apple.com/apps/6818509879/distribution/ios/version/inflight) has build 17 selected and remains **Prepare for Submission**. No App Store review submission or public release was made. Release is set to **manual**.

- English UK title, subtitle, description, promotional text, keywords, support URL and copyright are saved.
- Six iPhone and five iPad screenshots finished processing, in the agreed order.
- Price is free in all 175 territories. All territories and future territories are selected, subject to Apple's distribution requirements.
- Categories are Utilities and Productivity. The age questionnaire produces 4+ with regional exceptions.
- The privacy policy URL is saved and the approved **Data Not Collected** responses are published.
- The existing trader declaration is retained. The signed package declares no non-exempt encryption.
- Reviewer contact details and [Demo access instructions](review-notes.txt) are saved. Private reviewer details remain outside this public repository.

**Owner item:** App Information → Content Rights is pending confirmation of the necessary rights to third-party content. Provider permission work remains with the owner; no permission was inferred from successful login or API requests.

## Validation

175 unit tests passed; three opt-in live tests were skipped. Six native simulator checks passed: Demo restoration, history/events, notification settings, delivery while the app is closed, six-account widget persistence/deep links, and both Codex sign-in sheets and cancellation. Completed provider authorization was not repeated for this build.

The exact uploaded IPA was checked for matching app/widget versions, distribution signatures, the shared App Group, both privacy manifests, background modes/task identifiers and the encryption declaration. It was built with the iOS 26.5 SDK. See [the release record](../testflight-build-17.json) for the package hash and Apple status.

## Administration

`scripts/prepare-app-store.py` supports `metadata`, `screenshots`, `pricing`, `availability`, `select-build` and `verify`. Writes require `--apply` and an editable, unsubmitted version. Its API credentials are read from ignored `.release/apple.json`. It does not submit or release an App Store version.

After the owner declaration is complete, App Store review submission and eventual manual release are separate actions.
