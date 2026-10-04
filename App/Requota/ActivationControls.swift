import SwiftUI

struct ActivationControls: View {
    let account: AgentAccount
    var showsAccount = false
    @EnvironmentObject private var store: AccountStore
    @State private var showingHelp = false
    @State private var authorising = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(showsAccount ? account.title : "Weekly activation").font(.subheadline.weight(.semibold))
                    if showsAccount { Text(account.provider.name).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Button { showingHelp = true } label: {
                    Image(systemName: "info.circle").font(.subheadline).foregroundStyle(.secondary)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("About weekly activation")
                .accessibilityIdentifier("activation-help-" + account.id.uuidString)
                .popover(isPresented: $showingHelp) {
                    Text("Sends a small request using included allowance to start an unused weekly window. Automatic activation applies only to this account and runs during usage refreshes. Claude requires activation permission.")
                        .font(.subheadline).padding(16).frame(width: 280)
                        .accessibilityIdentifier("activation-explanation")
                        .presentationCompactAdaptation(.popover)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { manualAction; Spacer(minLength: 8); automaticToggle }
                VStack(alignment: .leading, spacing: 10) { automaticToggle; manualAction }
            }
            .font(.subheadline)
            if let message = store.activationMessages[account.id] {
                Text(message).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("activation-message")
            } else if let record = account.activation {
                Text(record.status == .started ? "Weekly window active." : "\([.failed, .attempted].contains(record.status) ? "Attempted" : "Request sent") \(record.attemptedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $authorising) { SignInView(account: account, allowActivation: true) }
    }

    private var automaticToggle: some View {
        Toggle("Automatic", isOn: Binding(get: {
            store.accounts.first { $0.id == account.id }?.automaticActivation == true
        }, set: { store.setAutomaticActivation($0, for: account.id) }))
            .fixedSize().disabled(store.isDemo)
            .accessibilityIdentifier("automatic-activation-" + account.id.uuidString)
    }
    @ViewBuilder private var manualAction: some View {
        if store.activationPermitted(account.id) {
            Button(store.activating.contains(account.id) ? "Starting…" : "Start week") {
                Task { await store.startAllowance(account.id) }
            }
            .buttonStyle(.borderless)
            .disabled(store.isDemo || store.activating.contains(account.id) || store.refreshing.contains(account.id) || account.needsLogin)
            .accessibilityIdentifier("start-week")
        } else if account.provider == .claude {
            Button("Allow activation") { authorising = true }.buttonStyle(.borderless).disabled(store.isDemo).accessibilityIdentifier("allow-activation")
        } else {
            Text("Unavailable").font(.caption).foregroundStyle(.secondary)
        }
    }
}
