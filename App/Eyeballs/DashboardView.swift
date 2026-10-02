import SwiftUI
import UniformTypeIdentifiers

extension UTType { static let eyeballsAccount = UTType(exportedAs: "com.dotdioscorea.eyeballs.account-order") }

struct RootView: View {
    @EnvironmentObject private var store: AccountStore
    @State private var path: [UUID] = []
    @State private var tab = 0
    @State private var reporting = false
    @State private var failedProvider: Provider?
    var body: some View {
        TabView(selection: $tab) {
            NavigationStack(path: $path) {
                DashboardView().navigationDestination(for: UUID.self) { id in AccountDetailView(id: id) }
            }.tabItem { Label("Accounts", systemImage: "circle.hexagongrid") }.tag(0)
            NavigationStack { ChartsView() }.tabItem { Label("Charts", systemImage: "chart.xyaxis.line") }.tag(1)
            NavigationStack { EventsView() }.tabItem { Label("Events", systemImage: "clock.arrow.circlepath") }.tag(3)
            NavigationStack { SettingsView() }.tabItem { Label("Settings", systemImage: "slider.horizontal.3") }.tag(2)
        }
        .alert("Error", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .alert("Usage could not be read", isPresented: Binding(get: { store.reportAccountID != nil }, set: { if !$0 { store.reportAccountID = nil } })) {
            Button("Report problem") { failedProvider = store.accounts.first { $0.id == store.reportAccountID }?.provider; store.reportAccountID = nil; reporting = true }
            Button("Not now", role: .cancel) { store.reportAccountID = nil }
        } message: { Text("The provider response may have changed. Your last usage reading has been kept.") }
        .sheet(isPresented: $reporting) { NavigationStack { ProblemReportView(title: "\(failedProvider?.name ?? "Provider") usage response could not be parsed", includeDebug: true).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { reporting = false } } } } }
        .onChange(of: store.notificationAccountID, initial: true) { _, value in
            guard let id = value, store.accounts.contains(where: { $0.id == id }) else { return }
            tab = 0; path = [id]; store.notificationAccountID = nil
        }
        .onOpenURL { url in
            guard url.scheme == "eyeballs" else { return }
            tab = 0
            if let id = UUID(uuidString: url.lastPathComponent), store.accounts.contains(where: { $0.id == id }) { path = [id] }
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject private var store: AccountStore
    @AppStorage("dashboard-compact") private var oldCompact = false
    @AppStorage("dashboard-layout") private var layoutValue = ""
    @State private var dragging: UUID?
    @State private var reordering = false
    private var layout: DashboardLayout { DashboardLayout(rawValue: layoutValue) ?? (oldCompact ? .bars : .cards) }
    private var compact: Bool { layout != .cards }
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
                Group {
                    if layout == .tiles {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            ForEach(displayed) { account in accountLink(account, tile: true) }
                        }
                    } else {
                        LazyVStack(spacing: compact ? 4 : 14) {
                            ForEach(displayed) { account in accountLink(account, tile: false) }
                        }
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
        .sheet(isPresented: $reordering) { reorderSheet }
    }
    private var controls: some View {
        VStack(spacing: compact ? 6 : 10) {
            HStack {
                HStack(spacing: 12) {
                    ForEach(DashboardLayout.allCases) { choice in
                        Button { layoutValue = choice.rawValue; oldCompact = choice == .bars } label: {
                            Image(systemName: choice.symbol).font(.subheadline).padding(.vertical, 5)
                        }.tint(layout == choice ? Theme.accent : .secondary)
                            .accessibilityLabel(choice.title).accessibilityValue(layout == choice ? "On" : "Off")
                            .accessibilityIdentifier(choice == .bars ? "compact-mode" : "layout-\(choice.rawValue)")
                    }
                }
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
                    Button("Reorder accounts") { adoptCustomOrder(); reordering = true }
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
    private func adoptCustomOrder() {
        if sort != .manual { store.reorder(sort.sorted(store.accounts).map(\.id)); sortValue = AccountSort.manual.rawValue }
    }
    private func accountLink(_ account: AgentAccount, tile: Bool) -> some View {
        NavigationLink(value: account.id) {
            if tile { AccountTile(account: account) } else { AccountCard(account: account, compact: layout == .bars) }
        }.buttonStyle(.plain).accessibilityIdentifier("account-\(account.title)")
            .onDrag {
                adoptCustomOrder(); dragging = account.id
                let item = NSItemProvider()
                item.registerDataRepresentation(forTypeIdentifier: UTType.eyeballsAccount.identifier, visibility: .ownProcess) { handler in handler(Data(account.id.uuidString.utf8), nil); return nil }
                return item
            }
            .onDrop(of: [UTType.eyeballsAccount], delegate: AccountDropDelegate(target: account.id, dragging: $dragging, store: store))
    }
    private var reorderSheet: some View {
        NavigationStack {
            List {
                ForEach(store.accounts) { account in
                    HStack { ProviderLogo(provider: account.provider, color: account.color, size: 20); Text(account.title) }
                }.onMove { offsets, destination in
                    var ids = store.accounts.map(\.id); ids.move(fromOffsets: offsets, toOffset: destination); store.reorder(ids)
                }
            }.environment(\.editMode, .constant(.active)).scrollContentBackground(.hidden).background(Theme.background)
                .navigationTitle("Account order").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { reordering = false } } }
        }
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

private struct AccountDropDelegate: DropDelegate {
    let target: UUID
    @Binding var dragging: UUID?
    let store: AccountStore
    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        withAnimation(.easeInOut(duration: 0.15)) { store.move(dragging, to: target) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}
struct AccountTile: View {
    let account: AgentAccount
    var body: some View {
        GeometryReader { geometry in
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let readings = account.readings(at: context.date)
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    ProviderLogo(provider: account.provider, color: account.color, size: 17)
                    Text(account.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                UsageRing(readings: readings, color: account.color, size: min(96, geometry.size.width * 0.48), lineWidth: readings.count > 2 ? 5 : 7)
                HStack(spacing: 8) {
                    ForEach(Array(readings.prefix(2).enumerated()), id: \.element.id) { index, reading in
                        Text("\(reading.window?.duration == 18000 ? "5h" : reading.window?.title ?? "Usage") \(reading.value)")
                            .foregroundStyle(MetricColor.color(index, base: account.color)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                }.font(.system(size: 10)).monospacedDigit()
                Text(account.needsLogin ? "Reconnect" : account.displayedReset(for: readings).map { $0 <= context.date ? "Reset due" : "Reset in \(ResetText.relative($0, now: context.date))" } ?? account.provider.name)
                    .font(.caption2).foregroundStyle(account.needsLogin ? .orange : .secondary).lineLimit(1)
                if let updated = account.snapshot?.updatedAt { Text(UpdatedText.relative(updated, now: context.date)).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1) }
            }.padding(10).frame(width: geometry.size.width, height: geometry.size.height)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.border, lineWidth: 1))
        }
        }.aspectRatio(1, contentMode: .fit)
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
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(provider.name).font(.body.weight(.semibold))
                                    if provider == .gemini { Text(provider.subtitle).font(.caption).foregroundStyle(.secondary) }
                                }
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
