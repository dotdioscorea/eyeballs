# TestFlight review handoff

This records a side conversation with Aaron about Requota’s first external TestFlight review. The side conversation inspected the current setup but did not change source, Apple metadata, tester assignments or the submission. Aaron requested this Markdown handoff for the implementing agent.

## Recommendation

Leave the submission queued while improving the review preparation. A possible rejection alone is not a reason to cancel. If investigation establishes a specific incompatibility that requires changing the submitted build, reconsider the submission then.

Aaron asked whether we should wait, make changes or cancel. He has not instructed us to cancel, remove providers or reintroduce a sample-account preview. His final request was to document the discussion.

## Verified state

Checked through read-only App Store Connect API requests during this conversation on 2 October 2026:

- Build **1.0 (8)** has internal state `IN_BETA_TESTING` and external state `WAITING_FOR_BETA_REVIEW`.
- `autoNotifyEnabled` is `true`.
- The English beta localization has a feedback email, but `privacyPolicyUrl` is blank. `marketingUrl` is also blank; we did not establish that a marketing URL is required.
- Review information has `demoAccountRequired: false` and notes explaining that there is no separate Requota account or backend. The notes suggest connecting a free GitHub Copilot account or an existing supported provider account.
- No reviewer demo credentials or release demo mode are provided by that setup. The README explicitly says there is no public preview mode.
- The app already has an accessible **Privacy & storage** screen with factual information about system-browser login, Keychain storage, local history, widgets, diagnostics and deletion.

Recheck the live review status before acting; these observations are a snapshot. Tony’s external access was awaiting this review in the parent conversation.

## Concrete preparation to address

1. **Publish a privacy policy and populate its metadata URL.** Keep it short, factual and consistent with the implementation. The current in-app privacy screen and README provide a starting point. Cover local storage and retention, direct provider requests, deletion, widget summaries and optional public GitHub reports. Avoid claiming that no data leaves the device: provider requests and deliberately submitted reports do leave it. Confirm whether the existing in-app screen sufficiently exposes the policy or needs a link to the published version.

2. **Provide a reliable reviewer testing path.** The current notes depend on reviewers having or creating their own provider accounts. Apple’s guidelines ask for an active demo account or a fully featured demo mode for account-based features. Determine a suitable approach rather than assuming `demoAccountRequired: false` establishes an exemption. Do not share Aaron’s personal credentials or automatically restore the preview feature he previously asked to remove. Review instructions should let Apple exercise account summaries, layouts, charts, events and widgets, while clearly identifying anything dependent on provider data or elapsed observation time.

3. **Verify permission for the provider integrations.** The source uses providers’ native/CLI public clients and account-usage interfaces. Successful authentication, public source code, read-only access and personal use do not by themselves establish permission for external distribution. Check the applicable current provider terms and any specific authorization; record what is established and what remains uncertain. We have not established that Apple will object, or that every integration is prohibited. Better review wording cannot substitute for permission where permission is required.

The privacy URL is a confirmed missing field. Reviewer access is a concrete preparation concern. Provider permission remains an unresolved question, not an observed Apple rejection.

## What was explained to Aaron

- Review includes human review alongside automated checks. The first external TestFlight build requires a full review; later builds of the same version may not require another full review.
- Allowing roughly a day or two is a planning estimate, not an Apple deadline. Apple’s published figure of 90% reviewed within 24 hours is a general App Review benchmark, not a TestFlight-specific guarantee.
- A routine rejection ordinarily leads to clarification, corrections and resubmission. It is not automatically a developer-account ban. The actual rejection reason matters: documentation or reviewer-access issues are generally easier to address than an objection to an integration’s permitted use.
- Submitting for TestFlight does not publish the app on the App Store.
- The assistant acknowledged that reviewer readiness and provider-permission uncertainty should have been checked and explained before submission. Aaron was concerned, but no cancellation was requested.

## Primary references

- [External TestFlight review and invitations](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers): first full review, later builds, review outcomes and tester notification.
- [Apple’s App Review timing guidance](https://developer.apple.com/distribute/app-review/): general 90%-within-24-hours figure.
- [Apple’s automated and human review process](https://support.apple.com/en-ie/guide/security/secb8f887a15/web).
- [Reviewer access and app completeness](https://developer.apple.com/app-store/review/guidelines/#app-completeness), plus the guidelines’ “Before You Submit” checklist: demo access requirements.
- [Privacy requirements, 5.1.1](https://developer.apple.com/app-store/review/guidelines/#privacy): accessible privacy policy and metadata link.
- [Third-party services, 5.2.2](https://developer.apple.com/app-store/review/guidelines/#intellectual-property): permitted use under service terms and authorization evidence upon request.
- [Correcting and resubmitting rejected submissions](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/manage-a-submission-with-unresolved-issues/). The external TestFlight guide separately provides its beta-review appeal route.

Private reviewer contact details, tester email addresses and authentication credentials are intentionally omitted from this handoff.
