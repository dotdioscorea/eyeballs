import SwiftUI

@MainActor
final class SignInModel: ObservableObject {
    @Published var working = false
    @Published var message: String?
    @Published var credential: AccountCredential?
    @Published var snapshot: UsageSnapshot?
    @Published var verificationCode: String?
    private let browser = OAuthBrowser()
    private let copilotBrowser = CopilotBrowser()
    private let signer: ((AccountCredential?) async throws -> AccountCredential)?
    private let fetcher: (AgentAccount, AccountCredential) async throws -> UsageSnapshot
    private var task: Task<Void, Never>?
    init(signer: ((AccountCredential?) async throws -> AccountCredential)? = nil,
         fetcher: @escaping (AgentAccount, AccountCredential) async throws -> UsageSnapshot = { try await UsageClient.fetch(account: $0, credential: $1) }) {
        self.signer = signer; self.fetcher = fetcher
    }
    func start(account: AgentAccount, previous: AccountCredential?, usePrivateSession: Bool = false) {
        guard !working else { return }
        working = true; message = nil; credential = nil; snapshot = nil; verificationCode = nil
        Diagnostics.$context.withValue(.init(provider: account.provider, accountID: account.id)) {
            Diagnostics.record(.signInStarted, privateSession: usePrivateSession)
        }
        task = Task {
          await Diagnostics.$context.withValue(.init(provider: account.provider, accountID: account.id)) {
            defer { working = false; verificationCode = nil }
            do {
                let connection: AccountCredential
                if let signer { connection = try await signer(previous) }
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
            catch { snapshot = nil; message = error.localizedDescription; Diagnostics.record(.signInFailed, provider: account.provider, failure: .category(error)) }
          }
        }
    }
    func openGitHub() { copilotBrowser.open() }
    func cancel() { task?.cancel(); task = nil; browser.cancel(); copilotBrowser.cancel(); verificationCode = nil }
}

struct SignInView: View {
    let account: AgentAccount
    @EnvironmentObject private var store: AccountStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = SignInModel()
    @State private var name = ""
    @State private var workstream = ""
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let snapshot = model.snapshot, let credential = model.credential {
                        HStack(spacing: 20) {
                            UsageRing(readings: AgentAccount(provider: account.provider, snapshot: snapshot).readings(), color: account.provider.color, size: 100)
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
                    } else {
                        HStack(spacing: 8) {
                            ProviderLogo(provider: account.provider, color: account.color, size: 22)
                            Text("Sign in with \(account.provider == .codex ? "ChatGPT" : account.provider.name).").font(.subheadline).foregroundStyle(.secondary)
                        }
                        if account.provider == .gemini { Text("Shows Gemini CLI and Code Assist quotas.").font(.caption).foregroundStyle(.secondary) }
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
                            do { model.start(account: account, previous: try store.savedCredential(for: account.id)) }
                            catch { model.message = error.localizedDescription }
                        } label: {
                            HStack { if model.working { ProgressView() }; Text(model.working ? "Connecting…" : "Continue with \(account.provider == .codex ? "ChatGPT" : account.provider.name)") }
                        }.buttonStyle(PrimaryButtonStyle()).disabled(model.working)
                        Button(account.snapshot == nil ? "Use another account" : "Choose a different sign-in") {
                            do { model.start(account: account, previous: try store.savedCredential(for: account.id), usePrivateSession: true) }
                            catch { model.message = error.localizedDescription }
                        }.font(.subheadline.weight(.medium)).tint(Theme.accent)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .disabled(model.working).accessibilityIdentifier("choose-another-login")
                        Text("Credentials protected by iPhone Keychain").font(.caption).foregroundStyle(.secondary)
                    }
                    if let message = model.message {
                        Label(message, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(.orange).panel()
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
                .onAppear { name = account.label; workstream = account.workstream }
                .onDisappear { model.cancel() }
        }.interactiveDismissDisabled(model.working)
    }
}
