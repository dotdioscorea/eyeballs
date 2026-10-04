import SwiftUI

@MainActor
final class SignInModel: ObservableObject {
    @Published var working = false
    @Published var message: String?
    @Published var credential: AccountCredential?
    @Published var snapshot: UsageSnapshot?
    @Published var reportSuggested = false
    @Published var verificationCode: String?
    @Published var inputEmail = ""
    @Published var inputCode = ""
    @Published var awaitingEmailCode = false
    private var emailAttempt: PerplexityAuth.Attempt?
    private let emailBegin: ((String) async throws -> PerplexityAuth.Attempt)?
    private let emailVerify: ((PerplexityAuth.Attempt, String, AccountCredential?) async throws -> AccountCredential)?
    private let browser = OAuthBrowser()
    private let copilotBrowser = CopilotBrowser()
    private let cursorBrowser = CursorBrowser()
    private let ampBrowser = AmpBrowser()
    private let clineBrowser = ClineBrowser()
    private let kimiBrowser = KimiBrowser()
    private let signer: ((AccountCredential?) async throws -> AccountCredential)?
    private let fetcher: (AgentAccount, AccountCredential) async throws -> UsageSnapshot
    private var task: Task<Void, Never>?
    init(signer: ((AccountCredential?) async throws -> AccountCredential)? = nil,
         fetcher: @escaping (AgentAccount, AccountCredential) async throws -> UsageSnapshot = { try await UsageClient.fetch(account: $0, credential: $1) },
         emailBegin: ((String) async throws -> PerplexityAuth.Attempt)? = nil,
         emailVerify: ((PerplexityAuth.Attempt, String, AccountCredential?) async throws -> AccountCredential)? = nil) {
        self.signer = signer; self.fetcher = fetcher; self.emailBegin = emailBegin; self.emailVerify = emailVerify
    }
    func start(account: AgentAccount, previous: AccountCredential?, usePrivateSession: Bool = false, kimiRegion: KimiAuth.Region = .global) {
        guard !working else { return }
        working = true; reportSuggested = false; message = nil; credential = nil; snapshot = nil; verificationCode = nil
        Diagnostics.$context.withValue(.init(provider: account.provider, accountID: account.id)) {
            Diagnostics.record(.signInStarted, privateSession: usePrivateSession)
        }
        task = Task {
          await Diagnostics.$context.withValue(.init(provider: account.provider, accountID: account.id)) {
            defer { working = false; verificationCode = nil }
            do {
                let connection: AccountCredential
                if let signer { connection = try await signer(previous) }
                else if account.provider == .perplexity { throw UsageError.unsupportedLogin }
                else if account.provider == .kimi {
                    connection = try await kimiBrowser.signIn(previous: previous, privateSession: usePrivateSession, region: kimiRegion)
                }
                else if account.provider == .amp {
                    connection = try await ampBrowser.signIn(previous: previous, privateSession: usePrivateSession)
                }
                else if account.provider == .cline {
                    connection = try await clineBrowser.signIn(previous: previous, privateSession: usePrivateSession)
                }
                else if account.provider == .cursor {
                    connection = try await cursorBrowser.signIn(previous: previous, privateSession: usePrivateSession)
                }
                else if account.provider == .copilot {
                    connection = try await copilotBrowser.signIn(previous: previous, privateSession: usePrivateSession) { [weak self] code in self?.verificationCode = code }
                }
                else { connection = try await browser.signIn(provider: account.provider, previous: previous, usePrivateSession: usePrivateSession) }
                try Task.checkCancellation()
                credential = connection
                Diagnostics.record(.identityVerified, provider: account.provider)
                // A verified identity does not prove quota access. Check the API before saving.
                snapshot = try await fetcher(account, connection)
                Diagnostics.record(.usageVerified, provider: account.provider)
                try Task.checkCancellation()
            } catch is CancellationError { credential = nil; snapshot = nil }
            catch { snapshot = nil; message = error.localizedDescription; if case UsageError.invalidResponse = error { reportSuggested = true }; Diagnostics.record(.signInFailed, provider: account.provider, failure: .category(error)) }
          }
        }
    }
    func openGitHub() { copilotBrowser.open() }
    func requestEmailCode(account: AgentAccount, previous: AccountCredential?) {
        guard !working, account.provider == .perplexity else { return }
        working = true; message = nil; reportSuggested = false; credential = nil; snapshot = nil; inputCode = ""
        task = Task {
            await Diagnostics.$context.withValue(.init(provider: .perplexity, accountID: account.id)) {
                defer { working = false }
                do {
                    Diagnostics.record(.signInStarted)
                    let attempt: PerplexityAuth.Attempt
                    if let emailBegin { attempt = try await emailBegin(previous?.email ?? inputEmail) }
                    else { attempt = try await PerplexityAuth.begin(email: previous?.email ?? inputEmail) }
                    try Task.checkCancellation()
                    emailAttempt = attempt; inputEmail = attempt.email; awaitingEmailCode = true
                } catch is CancellationError { }
                catch { message = error.localizedDescription; Diagnostics.record(.signInFailed, failure: .category(error)) }
            }
        }
    }
    func verifyEmailCode(account: AgentAccount, previous: AccountCredential?) {
        guard !working, account.provider == .perplexity, let attempt = emailAttempt else { return }
        working = true; message = nil; credential = nil; snapshot = nil
        let code = inputCode.trimmingCharacters(in: .whitespacesAndNewlines)
        task = Task {
            await Diagnostics.$context.withValue(.init(provider: .perplexity, accountID: account.id)) {
                defer { working = false }
                do {
                    let connection: AccountCredential
                    if let emailVerify { connection = try await emailVerify(attempt, code, previous) }
                    else { connection = try await PerplexityAuth.complete(attempt, code: code, previous: previous) }
                    try Task.checkCancellation(); credential = connection
                    inputCode = ""; emailAttempt = nil; awaitingEmailCode = false
                    Diagnostics.record(.identityVerified)
                    snapshot = try await fetcher(account, connection)
                    try Task.checkCancellation()
                    Diagnostics.record(.usageVerified)
                } catch is CancellationError { credential = nil; snapshot = nil }
                catch {
                    message = error.localizedDescription
                    if case UsageError.invalidResponse = error { reportSuggested = true }
                    Diagnostics.record(.signInFailed, failure: .category(error))
                }
            }
        }
    }
    func retryEmailUsage(account: AgentAccount) {
        guard !working, account.provider == .perplexity, let credential else { return }
        working = true; message = nil; reportSuggested = false
        task = Task {
            await Diagnostics.$context.withValue(.init(provider: .perplexity, accountID: account.id)) {
                defer { working = false }
                do {
                    let reading = try await fetcher(account, credential)
                    try Task.checkCancellation(); snapshot = reading
                    Diagnostics.record(.usageVerified)
                } catch is CancellationError { self.credential = nil; snapshot = nil }
                catch {
                    message = error.localizedDescription
                    if case UsageError.invalidResponse = error { reportSuggested = true }
                    Diagnostics.record(.signInFailed, failure: .category(error))
                }
            }
        }
    }
    func changeEmail() { guard !working else { return }; emailAttempt = nil; inputCode = ""; awaitingEmailCode = false; message = nil }
    func cancel() { task?.cancel(); task = nil; emailAttempt = nil; inputCode = ""; awaitingEmailCode = false; browser.cancel(); copilotBrowser.cancel(); cursorBrowser.cancel(); clineBrowser.cancel(); ampBrowser.cancel(); kimiBrowser.cancel(); verificationCode = nil }
}

struct SignInView: View {
    let account: AgentAccount
    @EnvironmentObject private var store: AccountStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = SignInModel()
    @State private var name = ""
    @State private var workstream = ""
    @State private var reporting = false
    @State private var emailLocked = false
    @State private var kimiRegion: KimiAuth.Region = .global
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if store.isDemo {
                        Text("Demo · Sample account").font(.subheadline)
                        TextField("Account name", text: $name).accessibilityIdentifier("new-account-name")
                        Button("Add sample account") { store.addDemoAccount(provider: account.provider, name: name); dismiss() }.buttonStyle(PrimaryButtonStyle())
                        Text("Exit Demo to sign in to a provider.").font(.caption).foregroundStyle(.secondary)
                    } else if let snapshot = model.snapshot, let credential = model.credential {
                        HStack(spacing: 20) {
                            let readings = AgentAccount(provider: account.provider, snapshot: snapshot).readings()
                            if readings.isEmpty, let balance = snapshot.formattedCreditBalance {
                                VStack(spacing: 5) {
                                    Text(balance).font(.title2.monospacedDigit())
                                    Text("Credits").font(.caption).foregroundStyle(.secondary)
                                }.frame(width: 100, height: 100)
                            } else if readings.isEmpty, let allowance = AgentAccount(provider: account.provider, snapshot: snapshot).primaryAllowance {
                                VStack(spacing: 4) {
                                    Text(allowance.remaining.map { $0.formatted() } ?? allowance.value).font(.title2.monospacedDigit())
                                    Text(allowance.title + (allowance.remaining != nil ? " left" : "")).font(.caption).foregroundStyle(.secondary)
                                }.frame(width: 100)
                            } else if readings.isEmpty {
                                Text(AgentAccount(provider: account.provider, snapshot: snapshot).allowanceSummary ?? (account.provider == .kimi ? "No Code quota reported" : "No quota reported")).font(.caption).foregroundStyle(.secondary).frame(width: 100)
                            } else {
                                UsageRing(readings: readings, color: account.provider.color, size: 100)
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Account verified", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.accent)
                                if let email = credential.email { Text(email).font(.subheadline).foregroundStyle(.secondary) }
                                Text(snapshot.plan ?? "Usage connected").font(.caption).foregroundStyle(.secondary)
                            }
                        }.panel()
                        VStack(spacing: 16) {
                            TextField("Account name, e.g. Personal", text: $name).textContentType(.nickname).accessibilityIdentifier("new-account-name")
                            Divider()
                            TextField("Workstream or machine", text: $workstream)
                        }.panel()
                        Button("Save connection") {
                            var connected = account
                            connected.snapshot = snapshot
                            connected.label = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
                            connected.workstream = String(workstream.prefix(160))
                            do { try store.connect(connected, credential: credential); dismiss() }
                            catch { model.message = error.localizedDescription }
                        }.buttonStyle(PrimaryButtonStyle()).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else if account.provider == .perplexity {
                        HStack(spacing: 8) { ProviderLogo(provider: .perplexity, color: account.color, size: 22); Text("Sign in with email.").font(.subheadline).foregroundStyle(.secondary) }
                        if model.credential != nil {
                            Button("Retry usage check") { model.retryEmailUsage(account: account) }
                                .buttonStyle(PrimaryButtonStyle()).disabled(model.working).accessibilityIdentifier("retry-perplexity-usage")
                            Button("Sign in again") { requestPerplexityCode() }.disabled(model.working).font(.subheadline)
                        } else if model.awaitingEmailCode {
                            Text("Code sent to \(model.inputEmail)").font(.subheadline)
                            TextField("6-digit code", text: $model.inputCode).textContentType(.oneTimeCode).keyboardType(.numberPad)
                                .accessibilityIdentifier("perplexity-code").disabled(model.working).panel()
                            Button {
                                do { model.verifyEmailCode(account: account, previous: try store.savedCredential(for: account.id)) }
                                catch { model.message = error.localizedDescription }
                            } label: { HStack { if model.working { ProgressView() }; Text(model.working ? "Verifying…" : "Verify code") } }
                                .buttonStyle(PrimaryButtonStyle()).disabled(model.working || model.inputCode.count != 6).accessibilityIdentifier("verify-perplexity-code")
                            Button("Send a new code") { requestPerplexityCode() }.disabled(model.working).font(.subheadline)
                            if !emailLocked { Button("Change email") { model.changeEmail() }.disabled(model.working).font(.subheadline) }
                        } else {
                            TextField("Email address", text: $model.inputEmail).textContentType(.emailAddress).keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("perplexity-email")
                                .disabled(model.working || emailLocked).panel()
                            Button { requestPerplexityCode() } label: { HStack { if model.working { ProgressView() }; Text(model.working ? "Sending…" : "Send sign-in code") } }
                                .buttonStyle(PrimaryButtonStyle()).disabled(model.working || model.inputEmail.isEmpty).accessibilityIdentifier("send-perplexity-code")
                        }
                        Text("Credentials protected by iPhone Keychain").font(.caption).foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 8) {
                            ProviderLogo(provider: account.provider, color: account.color, size: 22)
                            Text("Sign in with \(account.provider == .codex ? "ChatGPT" : account.provider.name).").font(.subheadline).foregroundStyle(.secondary)
                        }
                        if account.provider == .gemini { Text("Shows Gemini CLI and Code Assist quotas.").font(.caption).foregroundStyle(.secondary) }
                        if account.provider == .kimi, account.snapshot == nil {
                            Picker("Region", selection: $kimiRegion) { ForEach(KimiAuth.Region.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).disabled(model.working)
                        }
                        if let code = model.verificationCode {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("GitHub requires a one-time code.").font(.subheadline)
                                Text(code).font(.title2.monospaced().weight(.semibold)).accessibilityIdentifier("github-verification-code")
                                Button("Copy code and open GitHub") { model.openGitHub() }
                                    .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("open-github-verification")
                            }.panel()
                        }
                        if account.snapshot != nil {
                            Text("Reconnect only this account. Choose Add account to connect a different one.").font(.subheadline).foregroundStyle(.secondary).panel()
                        }
                        Button {
                            do { model.start(account: account, previous: try store.savedCredential(for: account.id), kimiRegion: kimiRegion) }
                            catch { model.message = error.localizedDescription }
                        } label: {
                            HStack { if model.working { ProgressView() }; Text(model.working ? "Connecting…" : "Continue with \(account.provider == .codex ? "ChatGPT" : account.provider.name)") }
                        }.buttonStyle(PrimaryButtonStyle()).disabled(model.working)
                        Button(account.snapshot == nil ? "Use another account" : "Choose a different sign-in") {
                            do { model.start(account: account, previous: try store.savedCredential(for: account.id), usePrivateSession: true, kimiRegion: kimiRegion) }
                            catch { model.message = error.localizedDescription }
                        }.font(.subheadline.weight(.medium)).tint(Theme.accent)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .disabled(model.working).accessibilityIdentifier("choose-another-login")
                        Text("Credentials protected by iPhone Keychain").font(.caption).foregroundStyle(.secondary)
                    }
                    if let message = model.message {
                        Text(message).font(.subheadline).foregroundStyle(.orange).panel()
                        if model.reportSuggested { Button("Report problem") { reporting = true } }
                        if account.provider == .gemini, model.credential != nil && model.snapshot == nil {
                            Link("Google Code Assist", destination: account.provider.usageURL).font(.subheadline)
                        }
                        if model.credential != nil && model.snapshot == nil {
                            Text("Sign-in completed, but usage access could not be verified. This connection has not been saved.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity)
            }.background(Theme.background)
                .navigationTitle("Connect \(account.provider.name)").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.cancel(); dismiss() } } }
                .onAppear {
                    name = account.label; workstream = account.workstream
                    if account.provider == .perplexity {
                        let email = (try? store.savedCredential(for: account.id))?.email
                        model.inputEmail = email ?? ""; emailLocked = email?.isEmpty == false
                    }
                }
                .onDisappear { model.cancel() }
        }.interactiveDismissDisabled(model.working).sheet(isPresented: $reporting) { NavigationStack { ProblemReportView(title: "\(account.provider.name) sign-in response could not be parsed", includeDebug: true).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { reporting = false } } } } }
    }
    private func requestPerplexityCode() {
        do { model.requestEmailCode(account: account, previous: try store.savedCredential(for: account.id)) }
        catch { model.message = error.localizedDescription }
    }
}
