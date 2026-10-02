# App Review testing

Build 8 is already queued for its first external TestFlight review. It has no release Demo mode. The published privacy policy was added to its beta localization on 2 October 2026. Do not describe the following Demo instructions as available in build 8.

## Demo in build 9

1. Open Settings → Demo. A persistent “Demo · Sample data” bar identifies the mode.
2. Open Accounts. Try cards, compact bars and square tiles; sorting, drag order, account edits, colours and ring configuration use the normal interfaces.
3. Open a sample account to inspect its rings, 30 days of sample history, line charts and daily, weekly and monthly heatmaps. Sample amounts use distinct units where applicable.
4. Open Charts to compare accounts and metrics. Open Events to inspect sample weekly resets, early resets and banked reset changes.
5. In Settings, enable the sample notification settings and configure their rules. “Test notification” explicitly requests iOS notification permission and sends a labelled sample reminder. “Simulate early reset” records a sample reset and banked reset use. “Reset sample data” restores the original examples.
6. Add an Eyeballs widget from the iOS widget gallery. During Demo, its account picker resolves the labelled sample accounts. Try single-account rings and several compact rows. Tapping a row opens its account in Demo.
7. Use Exit demo to return to real connections. Real credentials, accounts, history, events and notification rules are separate. Widgets return to the real summary cache. Widgets configured for demo-only accounts need a real account selected after leaving Demo.

Sample refreshes do not contact a provider. Add account in Demo adds a labelled sample; it does not pretend to authenticate. Exit Demo to exercise real system-browser sign-in with an account the reviewer is authorized to use. Provider sign-in, live parsing and future background delivery remain live-data-dependent features; sample data does not verify them.

The app has no Eyeballs account, developer backend, purchase flow or shared provider credentials. Privacy information is in Settings → Privacy & storage, including a link to the [published policy](https://dotdioscorea.github.io/eyeballs/). Reports are optional and submitted manually to public GitHub issues.

Apple’s [review guidelines](https://developer.apple.com/app-store/review/guidelines/#app-completeness) ask for full reviewer access. Section 2.1(a) says a built-in demo in place of an account for legal or security reasons requires prior Apple approval. Providing a Demo button is not evidence of that approval. Explain the third-party credential constraints and request acceptance of this testing path in the review notes; respond to any request for additional access.

The [provider permission investigation](provider-integration-permissions-2026-10-02.md) records separate integration concerns. A demo is not a workaround for those requirements.
