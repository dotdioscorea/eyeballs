import SwiftUI

struct AccountDetailView: View {
    let id: UUID
    @EnvironmentObject private var store: AccountStore
    @State private var editing = false
    @State private var configuring = false
    @State private var connecting = false
    @State private var removing = false
    private var account: AgentAccount? { store.accounts.first { $0.id == id } }
    var body: some View {
        Group {
            if let account {
                ScrollView {
                    VStack(spacing: 20) {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            VStack(spacing: 22) {
                                UsageRing(readings: account.readings(at: context.date), color: account.provider.color, size: 190, lineWidth: account.readings().count > 2 ? 10 : 13)
                                Text([account.provider.name, account.snapshot?.plan?.capitalized].compactMap { $0 }.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
                                MetricLegend(readings: account.readings(at: context.date), color: account.provider.color)
                            }.padding(.vertical, 16)
                        }
                        Button("Configure display") { configuring = true }.font(.subheadline.weight(.medium)).accessibilityIdentifier("configure-display")
                        if let snapshot = account.snapshot {
                            VStack(alignment: .leading, spacing: 18) {
                                ForEach(snapshot.windows) { window in
                                    let reading = MetricReading(definition: RingDefinition(windowID: window.id), window: window, direction: account.displaySettings.direction, date: .now)
                                    VStack(alignment: .leading, spacing: 7) {
                                        MetricBars(readings: [reading], color: account.provider.color)
                                        if let reset = window.resetsAt {
                                            Text(reset <= .now ? "Reset due" : "Resets \(reset.formatted(.dateTime.weekday(.abbreviated).hour().minute()))").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                if snapshot.windows.isEmpty { Text("No usage limit reported.").font(.subheadline).foregroundStyle(.secondary) }
                            }.panel()
                        }
                        UsageHistoryView(samples: store.histories[id] ?? [], account: account)
                        if let issue = account.issue { Text(issue).font(.subheadline).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).panel() }
                        VStack(alignment: .leading, spacing: 16) {
                            if !account.workstream.isEmpty { info("Workstream", value: account.workstream) }
                            if let email = account.snapshot?.email { info("Signed in as", value: email) }
                            if let credit = account.snapshot?.creditBalance { info("Credits", value: credit) }
                            if let billing = account.snapshot?.billingEndsAt { info("Billing period ends", value: billing.formatted(date: .abbreviated, time: .omitted)) }
                            if let reminder = account.renewalReminder { info("Renewal reminder", value: reminder.formatted(date: .abbreviated, time: .omitted)) }
                            if !account.notes.isEmpty { Text(account.notes).font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                            Button("Edit account") { editing = true }.font(.subheadline.weight(.medium))
                        }.panel()
                        if account.needsLogin { Button("Reconnect account") { connecting = true }.buttonStyle(PrimaryButtonStyle()) }
                        Link("Provider usage page", destination: account.provider.usageURL).font(.subheadline)
                        if let updated = account.snapshot?.updatedAt { Text("Last updated \(updated.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                        Button("Remove account", role: .destructive) { removing = true }.font(.subheadline).padding(.top, 8).accessibilityIdentifier("remove-connection")
                    }.padding(22).frame(maxWidth: 600).frame(maxWidth: .infinity)
                }.background(Theme.background).refreshable { await store.refresh(id) }
                    .navigationTitle(account.title).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) {
                        Button { var copy = account; copy.favorite.toggle(); store.update(copy) } label: { Image(systemName: account.favorite ? "star.fill" : "star") }.accessibilityLabel(account.favorite ? "Remove from favorites" : "Add to favorites")
                    } }
                    .sheet(isPresented: $editing) { EditAccountView(account: account) }
                    .sheet(isPresented: $configuring) { DisplaySettingsView(account: account) }
                    .sheet(isPresented: $connecting) { SignInView(account: account) }
                    .confirmationDialog("Remove \(account.title)?", isPresented: $removing, titleVisibility: .visible) {
                        Button("Remove account", role: .destructive) { do { try store.remove(id) } catch { store.error = error.localizedDescription } }
                    } message: { Text("Deletes its credentials and saved data from this iPhone.") }
            } else { ContentUnavailableView("Account removed", systemImage: "person.crop.circle.badge.minus") }
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
                Section {
                    TextField("Account name", text: $account.label).accessibilityIdentifier("account-name")
                    TextField("Workstream or machine", text: $account.workstream)
                    Toggle("Favorite", isOn: $account.favorite)
                }
                Section("Billing") {
                    Toggle("Renewal reminder", isOn: $reminderEnabled)
                    if reminderEnabled { DatePicker("Renewal date", selection: $reminderDate, displayedComponents: .date) }
                }
                Section("Notes") { TextField("Notes", text: $account.notes, axis: .vertical).lineLimit(4...8) }
            }.scrollContentBackground(.hidden).background(Theme.background)
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
struct DisplaySettingsView: View {
    @EnvironmentObject private var store: AccountStore
    @Environment(\.dismiss) private var dismiss
    let account: AgentAccount
    @State private var settings: AccountDisplay
    init(account: AgentAccount) { self.account = account; _settings = State(initialValue: account.displaySettings) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack { Spacer(); UsageRing(readings: account.readings(settings: settings), color: account.provider.color, size: 140, lineWidth: settings.rings.count > 2 ? 8 : 11); Spacer() }.padding(.vertical, 12)
                    Picker("Default amounts", selection: $settings.direction) { ForEach(AmountDirection.allCases) { Text($0.title).tag($0) } }.accessibilityIdentifier("amount-direction")
                }
                Section {
                    ForEach(Array(settings.rings.enumerated()), id: \.element.id) { index, ring in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Circle().fill(MetricColor.color(index, base: account.provider.color)).frame(width: 6, height: 6)
                                Text(account.readings(settings: settings)[index].title).font(.subheadline)
                            }
                            Picker("Amounts", selection: direction(for: ring)) {
                                Text("Default").tag(Optional<AmountDirection>.none)
                                ForEach(AmountDirection.allCases) { Text($0.title).tag(Optional($0)) }
                            }.font(.caption)
                        }
                    }.onDelete { settings.rings.remove(atOffsets: $0) }.onMove { settings.rings.move(fromOffsets: $0, toOffset: $1) }
                } header: { HStack { Text("Rings"); Spacer(); EditButton() } } footer: { Text("Up to four rings, outside to inside. Compact bars use the same metrics.") }
                Section("Available metrics") {
                    ForEach(account.snapshot?.windows ?? []) { window in
                        metricToggle(window, kind: .usage)
                        if window.duration != nil, window.resetsAt != nil { metricToggle(window, kind: .time) }
                    }
                }
                Section { Button("Reset display settings") { settings = AccountDisplay(rings: Array((account.snapshot?.windows ?? []).prefix(2)).map { RingDefinition(windowID: $0.id) }) } }
            }.scrollContentBackground(.hidden).background(Theme.background)
                .navigationTitle("Display").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { var copy = account; copy.display = settings; store.update(copy); dismiss() } }
                }
        }
    }
    private func direction(for ring: RingDefinition) -> Binding<AmountDirection?> {
        Binding(get: { settings.rings.first { $0.id == ring.id }?.direction }, set: { value in
            if let index = settings.rings.firstIndex(where: { $0.id == ring.id }) { settings.rings[index].direction = value }
        })
    }
    private func metricToggle(_ window: UsageWindow, kind: MetricKind) -> some View {
        let ring = RingDefinition(windowID: window.id, kind: kind)
        let selected = settings.rings.contains { $0.id == ring.id }
        return Toggle(window.title + (kind == .time ? " time" : " usage"), isOn: Binding(get: { selected }, set: { enabled in
            if enabled, settings.rings.count < 4 { settings.rings.append(ring) }
            else if !enabled { settings.rings.removeAll { $0.id == ring.id } }
        })).disabled(!selected && settings.rings.count >= 4).accessibilityIdentifier("metric-\(ring.id)")
    }
}
