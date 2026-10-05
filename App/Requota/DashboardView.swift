import SwiftUI
import UniformTypeIdentifiers

extension UTType { static let requotaAccount = UTType(exportedAs: "com.dotdioscorea.eyeballs.account-order") }

struct RootView: View {
    @EnvironmentObject private var store: AccountStore
    @State private var path: [UUID] = []
    @State private var tab = 0
    @State private var reporting = false
    @State private var failedProvider: Provider?
    init() {
        #if DEBUG
        if SimulatorFixtures.storeCaptureEnabled {
            _tab = State(initialValue: ["charts", "activity"].contains(SimulatorFixtures.captureScreen) ? 1 : SimulatorFixtures.captureScreen == "events" ? 3 : 0)
        }
        #endif
    }
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
    }
}

struct DashboardView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var textSize
    @EnvironmentObject private var store: AccountStore
    @AppStorage("dashboard-compact") private var oldCompact = false
    @AppStorage("dashboard-layout") private var layoutValue = ""
    @State private var dragging: UUID?
    @State private var reordering = false
    private var layout: DashboardLayout { DashboardLayout(rawValue: layoutValue) ?? (oldCompact ? .bars : .cards) }
    private var compact: Bool { layout != .cards }
    private var tablet: Bool { sizeClass == .regular }
    private var contentMargin: CGFloat { tablet ? 32 : (compact ? 12 : 16) }
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
            if textSize.isAccessibilitySize, !store.accounts.isEmpty { controls }
            if store.accounts.isEmpty {
                VStack(spacing: 22) {
                    RequotaMark(size: 100).padding(.top, 70)
                    Text("No accounts").font(.title2.weight(.semibold))
                    Button("Add account") { adding = true }.buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("connect-first")
                }.padding(24).frame(maxWidth: 500).frame(maxWidth: .infinity)
            } else {
                Group {
                    if layout == .tiles && !textSize.isAccessibilitySize {
                        LazyVGrid(columns: tablet ? [GridItem(.adaptive(minimum: 210, maximum: 280), spacing: 16)] : Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: tablet ? 16 : 10) {
                            ForEach(displayed) { account in accountLink(account, tile: true) }
                        }
                    } else if tablet && !textSize.isAccessibilitySize {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                            ForEach(displayed) { account in accountLink(account, tile: false) }
                        }
                    } else {
                        LazyVStack(spacing: compact ? 4 : 14) {
                            ForEach(displayed) { account in accountLink(account, tile: false) }
                        }
                    }
                    if displayed.isEmpty { ContentUnavailableView.search(text: search) }
                }.padding(.horizontal, contentMargin).padding(.top, tablet ? 16 : (compact ? 4 : 10)).padding(.bottom, tablet ? 32 : 20).frame(maxWidth: tablet ? 1280 : 650).frame(maxWidth: .infinity)
            }
        }
        .background(Theme.background).navigationTitle("Requota").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add account").accessibilityIdentifier("add-account")
        } }
        .safeAreaInset(edge: .top, spacing: 0) { if !store.accounts.isEmpty && !textSize.isAccessibilitySize { controls } }
        .refreshable { await store.refreshAll() }
        .sheet(isPresented: $adding) { AddAccountView() }
        .sheet(isPresented: $reordering) { reorderSheet }
        .onChange(of: connectedProviders) { _, providers in if let filter, !providers.contains(filter) { self.filter = nil } }
    }
    private var controls: some View {
        VStack(spacing: compact ? 6 : 10) {
            AccessibleStack(spacing: 12) {
                if tablet && !textSize.isAccessibilitySize { Text("Requota").font(.title2.weight(.semibold)); Spacer(minLength: 16); searchField.frame(maxWidth: 360) }
                HStack(spacing: 12) {
                    ForEach(DashboardLayout.allCases) { choice in
                        Button { layoutValue = choice.rawValue; oldCompact = choice == .bars } label: {
                            Image(systemName: choice.symbol).font(.subheadline).frame(minWidth: 44, minHeight: 44)
                        }.tint(layout == choice ? Theme.accent : .secondary)
                            .accessibilityLabel(choice.title).accessibilityValue(layout == choice ? "On" : "Off")
                            .accessibilityIdentifier(choice == .bars ? "compact-mode" : "layout-\(choice.rawValue)")
                    }
                }
                if !textSize.isAccessibilitySize { Spacer() }
                Menu {
                    Picker("Sort accounts", selection: $sortValue) { ForEach(AccountSort.allCases) { Text($0.title).tag($0.rawValue) } }
                    Button("Reorder accounts") { adoptCustomOrder(); reordering = true }
                } label: { Label(sort.title, systemImage: "arrow.up.arrow.down").font(.caption.weight(.medium)).fixedSize(horizontal: false, vertical: true).frame(minHeight: 44) }
                    .accessibilityLabel("Sort accounts").accessibilityIdentifier("sort-accounts")
            }
            if !tablet || textSize.isAccessibilitySize { searchField }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterButton("All", selected: filter == nil) { filter = nil }
                    ForEach(connectedProviders) { provider in filterButton(provider.name, selected: filter == provider) { filter = provider } }
                }
            }
        }.padding(.horizontal, contentMargin).padding(.top, tablet ? 18 : (compact ? 4 : 10)).padding(.bottom, tablet ? 8 : (compact ? 4 : 10)).frame(maxWidth: tablet ? 1280 : 650).frame(maxWidth: .infinity).background(Theme.background)
    }
    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search accounts", text: $search).font(.subheadline).accessibilityIdentifier("search-accounts")
            if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear search") }
        }.padding(compact && !tablet ? 7 : 9).background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
    }
    private var connectedProviders: [Provider] { Provider.allCases.filter { provider in store.accounts.contains { $0.provider == provider } } }
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
                item.registerDataRepresentation(forTypeIdentifier: UTType.requotaAccount.identifier, visibility: .ownProcess) { handler in handler(Data(account.id.uuidString.utf8), nil); return nil }
                return item
            }
            .onDrop(of: [UTType.requotaAccount], delegate: AccountDropDelegate(target: account.id, dragging: $dragging, store: store))
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
        Button(action: action) { Text(title).font(.caption.weight(.medium)).padding(.horizontal, 13).padding(.vertical, 7).frame(minHeight: 44).background(selected ? Theme.accent : Theme.card, in: Capsule()).foregroundStyle(selected ? Theme.background : .white.opacity(0.7)) }
    }
}

struct AccountCard: View {
    let account: AgentAccount
    var compact = false
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let readings = account.readings(at: context.date)
            VStack(alignment: .leading, spacing: compact ? 5 : 15) {
                AccessibleStack(spacing: compact ? 6 : 9) {
                    HStack(spacing: 8) {
                        ProviderLogo(provider: account.provider, color: account.color, size: compact ? 16 : 22)
                        Text(account.title).font(compact ? .subheadline.weight(.semibold) : .title3.weight(.semibold)).lineLimit(textSize.isAccessibilitySize ? nil : 1).layoutPriority(1)
                    }
                    if !textSize.isAccessibilitySize { Spacer(minLength: 8) }
                    Text([account.provider.name, account.planTitle].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(textSize.isAccessibilitySize ? nil : 1)
                }
                if !account.workstream.isEmpty { Text(account.workstream).font(.caption).foregroundStyle(.secondary).lineLimit(textSize.isAccessibilitySize ? nil : 1) }
                if !readings.isEmpty {
                if compact {
                    MetricBars(readings: readings, color: account.color, dense: true)
                }
                else {
                    AccessibleStack(spacing: 22) {
                        AccessibleUsageRing(readings: readings, color: account.color, size: 100, lineWidth: readings.count > 2 ? 6 : 8)
                        MetricLegend(readings: readings, color: account.color)
                    }
                }
                }
                if let allowances = account.snapshot?.remainingAllowances, !allowances.isEmpty { RemainingAllowancesView(allowances: allowances, dense: compact) }
                else if readings.isEmpty, account.snapshot?.formattedCreditBalance == nil { Text(account.emptyMetricMessage).font(.caption).foregroundStyle(.secondary) }
                if let credits = account.snapshot?.formattedCreditBalance {
                    AccessibleValueRow(title: "Credits", value: credits).font(compact ? .caption : .subheadline)
                    if !account.exhaustedWindows.isEmpty { Text(account.exhaustedWindows.map(\.title).joined(separator: ", ") + " allowance exhausted").font(.caption2).foregroundStyle(.orange) }
                }
                AccessibleStack(spacing: 8) {
                    if account.needsLogin { Text("Reconnect to update").foregroundStyle(.orange) }
                    else if let window = account.displayedResetWindow(for: readings), let reset = window.resetsAt { Text(reset <= context.date ? "\(window.shortTitle) reset due" : "\(window.shortTitle) resets in \(ResetText.relative(reset, now: context.date))").foregroundStyle(.secondary) }
                    if !textSize.isAccessibilitySize { Spacer(minLength: 0) }
                    if let snapshot = account.snapshot {
                        Text(UpdatedText.relative(snapshot.updatedAt, now: context.date) + (snapshot.isStale(at: context.date) ? " · stale" : "")).foregroundStyle(.secondary).multilineTextAlignment(textSize.isAccessibilitySize ? .leading : .trailing)
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
                let balance = account.snapshot?.formattedCreditBalance
                let ringSize = min(128, max(52, geometry.size.height - (balance == nil ? 102 : 120)))
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        ProviderLogo(provider: account.provider, color: account.color, size: 16)
                        Text(account.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 6)
                    if readings.isEmpty, let balance {
                        VStack(spacing: 5) {
                            Text(balance).font(.system(size: 26, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                            Text("Credits").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if readings.isEmpty, let allowance = account.primaryAllowance {
                        VStack(spacing: 5) {
                            Text(allowance.remaining.map { $0.formatted() } ?? allowance.value).font(.title.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
                            Text(allowance.title + (allowance.remaining != nil ? " left" : "")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    } else if readings.isEmpty {
                        Text(account.emptyMetricMessage).font(.caption).foregroundStyle(.secondary)
                    } else {
                        UsageRing(readings: readings, color: account.color, size: ringSize, lineWidth: readings.count > 2 ? 4 : 6, showsCaption: false)
                    }
                    Spacer(minLength: 6)
                    VStack(spacing: 6) {
                        if !readings.isEmpty {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: readings.count == 1 ? 1 : 2), alignment: .leading, spacing: 4) {
                                ForEach(Array(readings.enumerated()), id: \.element.id) { index, reading in
                                    HStack(spacing: 3) {
                                        Circle().fill(MetricColor.color(index, base: account.color)).frame(width: 4, height: 4)
                                        Text(tileTitle(reading)).foregroundStyle(.secondary).lineLimit(1)
                                        Text(reading.value).fontWeight(.medium).fixedSize()
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }.font(.system(size: 10)).monospacedDigit()
                            if let balance {
                                HStack(spacing: 4) {
                                    Text("Credits").foregroundStyle(.secondary)
                                    Spacer(minLength: 2)
                                    Text(balance).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7).fixedSize(horizontal: false, vertical: true)
                                }.font(.caption2)
                            }
                        }
                        if account.needsLogin { Text("Reconnect").font(.system(size: 10)).foregroundStyle(.orange) }
                        else if let updated = account.snapshot?.updatedAt {
                            Text(UpdatedText.relative(updated, now: context.date)).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }.padding(12).frame(width: geometry.size.width, height: geometry.size.height)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.border, lineWidth: 1))
            }
        }.aspectRatio(1, contentMode: .fit)
    }
    private func tileTitle(_ reading: MetricReading) -> String {
        let title = reading.window?.shortTitle ?? reading.definition.windowTitle ?? "Usage"
        return (title == "Weekly" ? "Wk" : title) + (reading.definition.kind == .time ? " time" : "")
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
                .sheet(item: $selected) { account in SignInView(account: account, onConnected: { id in
                    selected = nil; dismiss(); store.notificationAccountID = id
                }) }
                .onChange(of: store.accounts.count) { old, new in if new > old { dismiss() } }
        }
    }
}
