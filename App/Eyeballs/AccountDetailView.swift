import SwiftUI

struct AccountDetailView: View {
    let id: UUID
    @EnvironmentObject private var store: AccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var connecting = false
    @State private var removing = false
    private var account: AgentAccount? { store.accounts.first { $0.id == id } }
    var body: some View {
        Group {
            if let account {
                ScrollView {
                    VStack(spacing: 24) {
                        VStack(spacing: 18) {
                            ProviderMark(provider: account.provider, size: 42)
                            UsageRing(windows: account.snapshot?.windows ?? [], color: account.provider.color, size: 190, lineWidth: 13)
                            VStack(spacing: 6) {
                                Text(account.title).font(.title.weight(.semibold))
                                Text([account.provider.name, account.snapshot?.plan?.capitalized].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 12)
                        if let snapshot = account.snapshot {
                            VStack(alignment: .leading, spacing: 20) {
                                Text("YOUR ALLOWANCE").font(.caption.weight(.medium)).tracking(1.7).foregroundStyle(.secondary)
                                ForEach(snapshot.windows) { window in
                                    VStack(alignment: .leading, spacing: 10) {
                                        HStack {
                                            Text(window.title).font(.subheadline.weight(.medium))
                                            Spacer()
                                            Text(window.safePercent.map { "\(Int($0.rounded()))% used" } ?? "Not reported").font(.subheadline).monospacedDigit()
                                        }
                                        GeometryReader { geometry in
                                            ZStack(alignment: .leading) {
                                                Capsule().fill(account.provider.color.opacity(0.1))
                                                if let percent = window.safePercent { Capsule().fill(account.provider.color).frame(width: geometry.size.width * percent / 100) }
                                            }
                                        }.frame(height: 6).accessibilityHidden(true)
                                        HStack {
                                            if let reset = window.resetsAt {
                                                Text(reset <= .now ? "Reset due · update to confirm" : "Resets \(reset.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                                            } else { Text("Reset time not reported") }
                                            Spacer()
                                            if let pace = window.pace(), !snapshot.isStale() { Text(pace).foregroundStyle(account.provider.color) }
                                        }.font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                if snapshot.windows.isEmpty { Text("This provider hasn’t reported a usage limit for this account.").font(.subheadline).foregroundStyle(.secondary) }
                            }.panel()
                        }
                        if let issue = account.issue {
                            HStack(alignment: .top, spacing: 12) { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange); Text(issue).font(.subheadline).foregroundStyle(.secondary) }.panel()
                        }
                        VStack(alignment: .leading, spacing: 16) {
                            Text("ACCOUNT").font(.caption.weight(.medium)).tracking(1.7).foregroundStyle(.secondary)
                            info("Workstream", value: account.workstream.isEmpty ? "Add a workstream" : account.workstream)
                            if let email = account.snapshot?.email { info("Signed in as", value: email) }
                            if let credit = account.snapshot?.creditBalance { info("Credits", value: credit) }
                            if let billing = account.snapshot?.billingEndsAt { info("Billing period ends", value: billing.formatted(date: .abbreviated, time: .omitted)) }
                            if let reminder = account.renewalReminder { info("Your renewal reminder", value: reminder.formatted(date: .abbreviated, time: .omitted)) }
                            if !account.notes.isEmpty { Divider(); Text(account.notes).font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                            Button("Edit name, workstream & reminders") { editing = true }.font(.subheadline.weight(.medium))
                        }.panel()
                        VStack(spacing: 12) {
                            if account.needsLogin {
                                Button("Reconnect account") { connecting = true }.buttonStyle(PrimaryButtonStyle()).disabled(store.isDemo)
                            } else {
                                Button { Task { await store.refresh(id) } } label: {
                                    HStack { if store.refreshing.contains(id) { ProgressView() }; Text("Refresh usage") }
                                }.buttonStyle(PrimaryButtonStyle()).disabled(store.refreshing.contains(id) || store.isDemo)
                                Link("Open provider usage page", destination: account.provider.usageURL).font(.subheadline)
                            }
                            if let updated = account.snapshot?.updatedAt {
                                Text(store.isDemo ? "Sample data · preview only" : "Last checked \(updated.formatted(.relative(presentation: .named)))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button("Remove connection", role: .destructive) { removing = true }.font(.subheadline).padding(.top, 8).accessibilityIdentifier("remove-connection")
                        Text("Removing clears this connection’s credentials and usage from Eyeballs. Your other connections stay in place.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity)
                }.background(Theme.background)
                .navigationTitle(account.provider.name).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .primaryAction) {
                    Button { var updated = account; updated.favorite.toggle(); store.update(updated) } label: { Image(systemName: account.favorite ? "star.fill" : "star") }.accessibilityLabel(account.favorite ? "Remove from favorites" : "Add to favorites")
                } }
                .sheet(isPresented: $editing) { EditAccountView(account: account) }
                .sheet(isPresented: $connecting) { SignInView(account: account) }
                .confirmationDialog("Remove \(account.title)?", isPresented: $removing, titleVisibility: .visible) {
                    Button("Remove connection", role: .destructive) {
                        do {
                            try store.remove(id); dismiss()
                        } catch { store.error = error.localizedDescription }
                    }
                } message: { Text("Only this connection’s credentials and usage will be cleared from this iPhone and your Eyeballs widgets.") }
            } else { ContentUnavailableView("Account removed", systemImage: "checkmark.circle") }
        }
    }
    private func info(_ title: String, value: String) -> some View {
        HStack(alignment: .top) { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).multilineTextAlignment(.trailing).textSelection(.enabled) }.font(.subheadline)
    }
}

struct EditAccountView: View {
    @EnvironmentObject private var store: AccountStore
    @Environment(\.dismiss) private var dismiss
    @State var account: AgentAccount
    @State private var reminderEnabled: Bool
    @State private var reminderDate: Date
    init(account: AgentAccount) {
        _account = State(initialValue: account)
        _reminderEnabled = State(initialValue: account.renewalReminder != nil)
        _reminderDate = State(initialValue: account.renewalReminder ?? .now.addingTimeInterval(30 * 86400))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Make it yours") {
                    TextField("Account name", text: $account.label).accessibilityIdentifier("account-name")
                    TextField("Workstream or machine", text: $account.workstream)
                    Toggle("Show in favorites", isOn: $account.favorite)
                }
                Section {
                    Toggle("Keep a renewal date", isOn: $reminderEnabled)
                    if reminderEnabled { DatePicker("Renewal date", selection: $reminderDate, displayedComponents: .date) }
                } header: { Text("Billing") } footer: { Text("A date you enter yourself. Provider-reported billing periods are shown separately.") }
                Section("Notes") { TextField("Anything worth remembering", text: $account.notes, axis: .vertical).lineLimit(4...8) }
            }
            .scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle("Edit account").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") {
                    account.label = String(account.label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
                    account.workstream = String(account.workstream.prefix(160)); account.notes = String(account.notes.prefix(2000))
                    account.renewalReminder = reminderEnabled ? reminderDate : nil
                    store.update(account); dismiss()
                } }
            }
        }
    }
}
