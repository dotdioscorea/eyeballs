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
        .alert("Error", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
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
    @AppStorage("dashboard-compact") private var compact = false
    @AppStorage("dashboard-sort") private var sortValue = AccountSort.favorites.rawValue
    @State private var adding = false
    @State private var search = ""
    @State private var filter: Provider?
    @State private var searching = false
    private var sort: AccountSort { AccountSort(rawValue: sortValue) ?? .favorites }
    private var displayed: [AgentAccount] {
        sort.sorted(store.accounts.filter { account in
            (filter == nil || account.provider == filter) && (search.isEmpty || [account.title, account.provider.name, account.workstream].joined(separator: " ").localizedCaseInsensitiveContains(search))
        })
    }
    var body: some View {
        ScrollView {
            if store.accounts.isEmpty {
                VStack(spacing: 22) {
                    EyeballsMark(size: 100).padding(.top, 70)
                    Text("No accounts").font(.title2.weight(.semibold))
                    Button("Add account") { adding = true }.buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("connect-first")
                }.padding(24).frame(maxWidth: 500).frame(maxWidth: .infinity)
            } else {
                LazyVStack(spacing: compact ? 4 : 14) {
                    ForEach(displayed) { account in
                        NavigationLink(value: account.id) { AccountCard(account: account, compact: compact) }
                            .buttonStyle(.plain).accessibilityIdentifier("account-\(account.title)")
                    }
                    if displayed.isEmpty { ContentUnavailableView.search(text: search) }
                }.padding(.horizontal, compact ? 12 : 16).padding(.top, compact ? 4 : 10).padding(.bottom, 20).frame(maxWidth: 650).frame(maxWidth: .infinity)
            }
        }
        .background(Theme.background).navigationTitle("Eyeballs").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add account").accessibilityIdentifier("add-account")
        } }
        .safeAreaInset(edge: .top, spacing: 0) { if !store.accounts.isEmpty { controls } }
        .refreshable { await store.refreshAll() }
        .sheet(isPresented: $adding) { AddAccountView() }
    }
    private var controls: some View {
        VStack(spacing: compact ? 6 : 10) {
            HStack {
                Button { compact.toggle() } label: {
                    Label("Compact", systemImage: compact ? "checkmark.square.fill" : "square")
                        .font(.subheadline).padding(.vertical, 5)
                }.tint(Theme.accent).accessibilityValue(compact ? "On" : "Off").accessibilityIdentifier("compact-mode")
                Spacer()
                if compact {
                    Button { searching.toggle() } label: { Image(systemName: "magnifyingglass") }.accessibilityLabel("Search accounts")
                    Menu {
                        Button("All providers") { filter = nil }
                        ForEach(Provider.allCases) { provider in Button(provider.name) { filter = provider } }
                    } label: { Text(filter?.name ?? "All").font(.caption) }.accessibilityLabel("Filter provider")
                }
                Menu {
                    Picker("Sort accounts", selection: $sortValue) { ForEach(AccountSort.allCases) { Text($0.title).tag($0.rawValue) } }
                } label: { Label(sort.title, systemImage: "arrow.up.arrow.down").font(.caption.weight(.medium)) }
                    .accessibilityLabel("Sort accounts").accessibilityIdentifier("sort-accounts")
            }
            if !compact || searching || !search.isEmpty { HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search accounts", text: $search).font(.subheadline).accessibilityIdentifier("search-accounts")
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear search") }
            }.padding(9).background(Theme.card, in: RoundedRectangle(cornerRadius: 10)) }
            if !compact { ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterButton("All", selected: filter == nil) { filter = nil }
                    ForEach(Provider.allCases) { provider in filterButton(provider.name, selected: filter == provider) { filter = provider } }
                }
            } }
        }.padding(.horizontal, 16).padding(.vertical, compact ? 4 : 10).background(Theme.background)
    }
    private func filterButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.caption.weight(.medium)).padding(.horizontal, 13).padding(.vertical, 7).background(selected ? Theme.accent : Theme.card, in: Capsule()).foregroundStyle(selected ? Theme.background : .white.opacity(0.7)) }
    }
}

struct AccountCard: View {
    let account: AgentAccount
    var compact = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let readings = account.readings(at: context.date)
            VStack(alignment: .leading, spacing: compact ? 5 : 15) {
                HStack(spacing: compact ? 6 : 9) {
                    ProviderLogo(provider: account.provider, color: account.color, size: compact ? 16 : 22)
                    Text(account.title).font(compact ? .subheadline.weight(.semibold) : .title3.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text([account.provider.name, account.snapshot?.plan?.capitalized].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if !account.workstream.isEmpty { Text(account.workstream).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if !readings.isEmpty {
                if compact {
                    MetricBars(readings: readings, color: account.color, dense: true)
                }
                else {
                    HStack(spacing: 22) {
                        UsageRing(readings: readings, color: account.color, size: 100, lineWidth: readings.count > 2 ? 6 : 8)
                        MetricLegend(readings: readings, color: account.color)
                    }
                }
                }
                if readings.isEmpty, let credits = account.snapshot?.creditBalance { Text("Credits: \(credits)").font(.subheadline) }
                HStack(alignment: .top, spacing: 8) {
                    if account.needsLogin { Text("Reconnect to update").foregroundStyle(.orange) }
                    else if let reset = account.displayedReset(for: readings) { Text(reset <= context.date ? "Reset due" : "Reset in \(ResetText.relative(reset, now: context.date))").foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                    if let snapshot = account.snapshot {
                        Text(UpdatedText.relative(snapshot.updatedAt, now: context.date) + (snapshot.isStale(at: context.date) ? " · stale" : "")).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                }.font(.caption2)
            }.padding(compact ? 8 : 18).background(Theme.card, in: RoundedRectangle(cornerRadius: compact ? 9 : 22))
                .overlay(RoundedRectangle(cornerRadius: compact ? 9 : 22).strokeBorder(Theme.border, lineWidth: 1))
        }
    }
}

struct AddAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AccountStore
    @State private var selected: AgentAccount?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(Provider.allCases) { provider in
                        Button { selected = AgentAccount(provider: provider) } label: {
                            HStack {
                                ProviderLogo(provider: provider, color: provider.color, size: 24)
                                Text(provider.name).font(.body.weight(.semibold))
                                Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }.panel()
                        }.buttonStyle(.plain).accessibilityIdentifier("connect-\(provider.rawValue)")
                    }
                }.padding(20).frame(maxWidth: 600).frame(maxWidth: .infinity)
            }.background(Theme.background).navigationTitle("Add account").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
                .sheet(item: $selected) { account in SignInView(account: account) }
                .onChange(of: store.accounts.count) { old, new in if new > old { dismiss() } }
        }
    }
}
