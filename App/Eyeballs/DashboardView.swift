import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AccountStore
    @State private var path: [UUID] = []
    @State private var tab = 0
    var body: some View {
        TabView(selection: $tab) {
            NavigationStack(path: $path) {
                DashboardView().navigationDestination(for: UUID.self) { id in AccountDetailView(id: id) }
            }.tabItem { Label("Accounts", systemImage: "circle.hexagongrid") }.tag(0)
            NavigationStack { ResetTimelineView() }.tabItem { Label("Resets", systemImage: "clock.arrow.circlepath") }.tag(1)
            NavigationStack { SettingsView() }.tabItem { Label("Settings", systemImage: "slider.horizontal.3") }.tag(2)
        }
        .alert("Something needs attention", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .onOpenURL { url in
            guard url.scheme == "eyeballs" else { return }
            tab = 0
            if let id = UUID(uuidString: url.lastPathComponent), store.accounts.contains(where: { $0.id == id }) { path = [id] }
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject private var store: AccountStore
    @State private var adding = false
    @State private var search = ""
    @State private var filter: Provider?
    private var displayed: [AgentAccount] {
        store.accounts.filter { account in
            (filter == nil || account.provider == filter) && (search.isEmpty || [account.title, account.provider.name, account.workstream].joined(separator: " ").localizedCaseInsensitiveContains(search))
        }.sorted { lhs, rhs in lhs.favorite == rhs.favorite ? lhs.addedAt < rhs.addedAt : lhs.favorite }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    HStack(spacing: 10) { EyeballsMark(); Text("eyeballs").font(.system(size: 27, weight: .semibold, design: .rounded)).tracking(-1) }
                    Spacer()
                    Button { adding = true } label: { Image(systemName: "plus").font(.title3).frame(width: 44, height: 44).background(Theme.card, in: Circle()) }
                        .accessibilityLabel("Add account").accessibilityIdentifier("add-account").disabled(store.isDemo)
                }
                if store.isDemo {
                    HStack {
                        Label("Preview · sample accounts", systemImage: "sparkles").font(.caption.weight(.medium))
                        Spacer(); Button("Exit preview") { store.endDemo() }.font(.caption.weight(.semibold))
                    }.padding(12).background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                }
                if store.accounts.isEmpty { welcome }
                else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("A little clarity.").font(.system(size: 34, weight: .semibold)).tracking(-1)
                        Text("Your AI accounts, all in sight.").font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let next = store.accounts.compactMap({ account -> (AgentAccount, Date)? in account.nextReset.map { (account, $0) } }).min(by: { $0.1 < $1.1 }) {
                        HStack(spacing: 14) {
                            Image(systemName: "arrow.counterclockwise").foregroundStyle(Theme.accent).font(.title3)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("UP NEXT").font(.caption2.weight(.semibold)).tracking(1.7).foregroundStyle(.secondary)
                                Text("\(next.0.provider.name) · \(next.0.title)").font(.subheadline.weight(.medium))
                            }
                            Spacer()
                            TimelineView(.periodic(from: .now, by: 60)) { context in Text(ResetText.relative(next.1, now: context.date)).font(.title3.weight(.semibold)).monospacedDigit() }
                        }.panel()
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            filterButton("All accounts", selected: filter == nil) { filter = nil }
                            ForEach(Provider.allCases) { provider in filterButton(provider.name, selected: filter == provider) { filter = provider } }
                        }
                    }
                    LazyVStack(spacing: 14) {
                        ForEach(displayed) { account in
                            NavigationLink(value: account.id) { AccountCard(account: account) }.buttonStyle(.plain).accessibilityIdentifier("account-\(account.title)")
                        }
                    }
                    if displayed.isEmpty { ContentUnavailableView.search(text: search) }
                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield"); Text("Credentials stay on this iPhone.")
                    }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 4)
                }
            }.padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 28).frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
        }
        .background(Theme.background).toolbar(.hidden, for: .navigationBar)
        .refreshable { await store.refreshAll() }
        .sheet(isPresented: $adding) { AddAccountView() }
    }
    private func filterButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.caption.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 10).background(selected ? Theme.accent : Theme.card, in: Capsule()).foregroundStyle(selected ? Theme.background : .white.opacity(0.7)) }
    }
    private var welcome: some View {
        VStack(spacing: 28) {
            ZStack {
                Circle().fill(Theme.accent.opacity(0.035)).frame(width: 270, height: 270)
                UsageRing(windows: DemoAccounts.accounts[0].snapshot!.windows, color: Theme.accent, size: 194, lineWidth: 14, showsNumber: false).rotationEffect(.degrees(-15))
                EyeballsMark(size: 96)
            }.padding(.top, 36).accessibilityHidden(true)
            VStack(spacing: 12) {
                Text("Keep an eye\non your AI.").font(.system(size: 42, weight: .semibold)).tracking(-1.5).multilineTextAlignment(.center)
                Text("Usage, resets and a little breathing room.\nAll your accounts in one quiet place.").font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4)
            }
            VStack(spacing: 18) {
                Button("Connect your first account") { adding = true }.buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("connect-first")
                Button("Take a look around") { store.startDemo() }.font(.subheadline.weight(.medium)).foregroundStyle(.secondary).accessibilityIdentifier("preview")
            }.padding(.top, 10)
            Label("Private by design. No Eyeballs account needed.", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity)
    }
}

struct AccountCard: View {
    let account: AgentAccount
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 10) {
                ProviderMark(provider: account.provider, size: 32)
                Text(account.provider.name).font(.subheadline.weight(.semibold))
                if let plan = account.snapshot?.plan { Text(plan.capitalized).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 4).background(.white.opacity(0.05), in: Capsule()) }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            HStack(spacing: 22) {
                UsageRing(windows: account.snapshot?.windows ?? [], color: account.provider.color, size: 98)
                VStack(alignment: .leading, spacing: 7) {
                    Text(account.title).font(.title3.weight(.semibold)).lineLimit(1)
                    if !account.workstream.isEmpty { Text(account.workstream).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    ForEach(Array((account.snapshot?.windows ?? []).prefix(2).enumerated()), id: \.offset) { index, window in
                        HStack(spacing: 7) {
                            Circle().fill(account.provider.color.opacity(index == 0 ? 1 : 0.45)).frame(width: 5, height: 5)
                            Text(window.title).font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 2)
                            Text(window.safePercent.map { "\(Int($0.rounded()))%" } ?? "—").font(.caption.weight(.medium)).monospacedDigit()
                        }
                    }
                }
            }
            HStack {
                if account.needsLogin {
                    Label("Reconnect to update", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                } else if let snapshot = account.snapshot, snapshot.isStale() {
                    Label(snapshot.windows.contains { $0.resetDue() } ? "Reset due · refresh" : "Reading needs an update", systemImage: "clock").foregroundStyle(.secondary)
                } else if let reset = account.nextReset {
                    TimelineView(.periodic(from: .now, by: 60)) { context in Label("Resets in \(ResetText.relative(reset, now: context.date))", systemImage: "arrow.counterclockwise") }.foregroundStyle(.secondary)
                } else { Text("Reset time unavailable").foregroundStyle(.secondary) }
                Spacer()
                if let percent = account.snapshot?.windows.first?.safePercent, percent >= 90 { Text("Nearly full").foregroundStyle(account.provider.color) }
            }.font(.caption)
        }.panel()
    }
}

struct AddAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AccountStore
    @State private var selected: AgentAccount?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Bring your accounts\ninto view.").font(.system(size: 34, weight: .semibold)).tracking(-1).padding(.top, 20)
                    Text("Add multiple accounts from the same provider. Give each connection a name and a workstream.").foregroundStyle(.secondary).font(.subheadline)
                    VStack(spacing: 12) {
                        ForEach(Provider.allCases) { provider in
                            Button { selected = AgentAccount(provider: provider) } label: {
                                HStack(spacing: 16) {
                                    ProviderMark(provider: provider, size: 46)
                                    VStack(alignment: .leading, spacing: 5) { Text(provider.name).font(.body.weight(.semibold)); Text("Continue with \(provider == .codex ? "ChatGPT" : provider.name)").font(.caption).foregroundStyle(.secondary) }
                                    Spacer(); Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                                }.panel()
                            }.buttonStyle(.plain).accessibilityIdentifier("connect-\(provider.rawValue)")
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Your credentials stay yours", systemImage: "lock.shield").font(.subheadline.weight(.medium))
                        Text("Sign-in opens the provider’s secure system-browser flow. Each connection has its own credentials in your iPhone’s Keychain. Removing one leaves your other connections intact.")
                            .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
                    }.padding(.top, 6)
                }.padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity)
            }.background(Theme.background)
                .navigationTitle("Add account").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
                .sheet(item: $selected) { account in SignInView(account: account) }
                .onChange(of: store.accounts.count) { old, new in if new > old { dismiss() } }
        }
    }
}
