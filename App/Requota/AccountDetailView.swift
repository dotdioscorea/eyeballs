import SwiftUI

struct AccountDetailView: View {
    let id: UUID
    @EnvironmentObject private var store: AccountStore
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var editing = false
    @State private var configuring = false
    @State private var connecting = false
    @State private var removing = false
    @State private var reporting = false
    private var account: AgentAccount? { store.accounts.first { $0.id == id } }
    var body: some View {
        Group {
            if let account {
                ScrollView {
                    VStack(spacing: 20) {
                        if textSize.isAccessibilitySize { Text(account.title).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading) }
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            VStack(spacing: 22) {
                                if !account.readings().isEmpty { AccessibleUsageRing(readings: account.readings(at: context.date), color: account.color, size: 190, lineWidth: account.readings().count > 2 ? 10 : 13) }
                                Text([account.provider.name, account.planTitle].compactMap { $0 }.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
                                if !account.readings().isEmpty { MetricLegend(readings: account.readings(at: context.date), color: account.color) }
                            }.padding(.vertical, account.readings().isEmpty ? 0 : 16)
                        }
                        Button("Configure display") { configuring = true }.font(.subheadline.weight(.medium)).accessibilityIdentifier("configure-display")
                        if let snapshot = account.snapshot, !snapshot.windows.isEmpty || snapshot.remainingAllowances?.isEmpty == false || snapshot.formattedCreditBalance == nil {
                            VStack(alignment: .leading, spacing: 18) {
                                ForEach(snapshot.windows) { window in
                                    let reading = MetricReading(definition: RingDefinition(windowID: window.id), window: window, direction: account.displaySettings.direction, date: .now)
                                    VStack(alignment: .leading, spacing: 7) {
                                        MetricBars(readings: [reading], color: account.usageColor(for: window.id))
                                        if let reset = window.resetsAt {
                                            Text(reset <= .now ? "Reset due" : "Resets \(reset.formatted(.dateTime.weekday(.abbreviated).hour().minute()))").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                if let allowances = snapshot.remainingAllowances, !allowances.isEmpty { RemainingAllowancesView(allowances: allowances) }
                                else if snapshot.windows.isEmpty { Text("No usage limit reported.").font(.subheadline).foregroundStyle(.secondary) }
                            }.panel()
                        }
                        if account.snapshot?.details?.credits != nil || (account.snapshot?.formattedCreditBalance != nil && account.snapshot?.details?.spending.contains(where: { $0.balance != nil }) != true) {
                            VStack(alignment: .leading, spacing: 8) {
                                if let credit = account.snapshot?.formattedCreditBalance { info("Credits", value: credit) }
                                else { Text("Credits").font(.subheadline.weight(.semibold)) }
                                if let details = account.snapshot?.details?.credits { CreditDetailsView(details: details) }
                                if !account.exhaustedWindows.isEmpty { Text(account.exhaustedWindows.map(\.shortTitle).joined(separator: ", ") + " allowance exhausted").font(.caption).foregroundStyle(.secondary) }
                            }.panel()
                        }
                        if let details = account.snapshot?.details { ProviderDetailsView(details: details, breakdownColor: account.usageColor(for: account.window(for: .weekly)?.id ?? "")) }
                        if let resets = account.snapshot?.bankedResets, !resets.isEmpty || account.snapshot?.resetInventory != nil {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Banked resets").font(.subheadline.weight(.semibold))
                                if resets.isEmpty { Text("None available").font(.caption).foregroundStyle(.secondary) }
                                ForEach(resets) { reset in
                                    AccessibleStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("\(reset.count) × \(reset.title)")
                                            if let first = reset.firstDetectedAt { Text("Detected \(first.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary) }
                                            if reset.usableNow == false { Text("Not usable yet").foregroundStyle(.secondary) }
                                        }
                                        Text(reset.expiresAt.map { "Expires \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "No expiry reported").foregroundStyle(.secondary)
                                    }.font(.caption)
                                }
                                if let checked = account.snapshot?.resetInventory?.checkedAt, let updated = account.snapshot?.updatedAt, updated.timeIntervalSince(checked) > 60 {
                                    Text("Last checked \(checked.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).panel()
                        }
                        if account.snapshot?.remainingAllowances?.isEmpty == false, account.snapshot?.windows.isEmpty != false {
                            RemainingAllowanceHistoryView(samples: store.histories[id] ?? [], account: account)
                        } else if account.snapshot?.windows.isEmpty == false || (store.histories[id] ?? []).contains(where: { !$0.windows.isEmpty }) {
                            UsageHistoryView(samples: store.histories[id] ?? [], account: account, events: store.events.filter { $0.accountID == id })
                        }
                        if AllowanceActivation.supported(account.provider), !store.isDemo {
                            ActivationControls(account: account).panel()
                        }
                        if let issue = account.issue { VStack(alignment: .leading, spacing: 10) { Text(issue).font(.subheadline).foregroundStyle(.orange); if account.needsReport == true { Button("Report problem") { reporting = true } } }.frame(maxWidth: .infinity, alignment: .leading).panel() }
                        VStack(alignment: .leading, spacing: 16) {
                            if !account.workstream.isEmpty { info("Workstream", value: account.workstream) }
                            if let email = account.snapshot?.email { info("Signed in as", value: email) }
                            if let billing = account.snapshot?.billingEndsAt { info("Billing period ends", value: billing.formatted(date: .abbreviated, time: .omitted)) }
                            if let reminder = account.renewalReminder { info("Renewal reminder", value: reminder.formatted(date: .abbreviated, time: .omitted)) }
                            if !account.notes.isEmpty { Text(account.notes).font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                            Button("Edit account") { editing = true }.font(.subheadline.weight(.medium))
                        }.panel()
                        if account.needsLogin { Button("Reconnect account") { connecting = true }.buttonStyle(PrimaryButtonStyle()) }
                        Link("Provider usage page", destination: account.usageURL).font(.subheadline)
                        if let updated = account.snapshot?.updatedAt { Text("Last updated \(updated.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                        Button("Remove account", role: .destructive) { removing = true }.font(.subheadline).padding(.top, 8).accessibilityIdentifier("remove-connection")
                    }.padding(22).frame(maxWidth: 600).frame(maxWidth: .infinity)
                }.id(account.id).background(Theme.background).refreshable { await store.refresh(id) }
                    .navigationTitle(account.title).navigationBarTitleDisplayMode(.inline)
                    .toolbar(.hidden, for: .tabBar)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) {
                        Button { var copy = account; copy.favorite.toggle(); store.update(copy) } label: { Image(systemName: account.favorite ? "star.fill" : "star") }.accessibilityLabel(account.favorite ? "Remove from favorites" : "Add to favorites")
                    } }
                    .sheet(isPresented: $reporting) { NavigationStack { ProblemReportView(title: "\(account.provider.name) usage response could not be parsed", includeDebug: true).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { reporting = false } } } } }
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
        AccessibleValueRow(title: title, value: value).font(.subheadline).textSelection(.enabled)
    }
}
struct EditAccountView: View {
    @EnvironmentObject private var store: AccountStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var textSize
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
                    AccessibleToggle("Favorite", isOn: $account.favorite)
                }
                Section("Billing") {
                    AccessibleToggle("Renewal reminder", isOn: $reminderEnabled)
                    if reminderEnabled {
                        if textSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Renewal date")
                                DatePicker("Renewal date", selection: $reminderDate, displayedComponents: .date).labelsHidden().accessibilityLabel("Renewal date")
                            }
                        } else { DatePicker("Renewal date", selection: $reminderDate, displayedComponents: .date) }
                    }
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
    @Environment(\.dynamicTypeSize) private var textSize
    let account: AgentAccount
    @State private var settings: AccountDisplay
    init(account: AgentAccount) { self.account = account; _settings = State(initialValue: account.displaySettings); _colorHex = State(initialValue: account.colorHex) }
    var body: some View {
        NavigationStack {
            Form {
                if !settings.rings.isEmpty || account.snapshot?.windows.isEmpty == false {
                Section {
                    HStack { Spacer(); AccessibleUsageRing(readings: account.readings(settings: settings), color: colorHex.map { Color(hex: $0) } ?? account.provider.color, size: 140, lineWidth: settings.rings.count > 2 ? 8 : 11); Spacer() }.padding(.vertical, 12)
                    AccessibleFormPicker("Default amounts", selection: $settings.direction, options: AmountDirection.allCases.map { ($0.title, $0) }, identifier: "amount-direction")
                }
                Section {
                    ForEach(Array(settings.rings.enumerated()), id: \.element.id) { index, ring in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Circle().fill(MetricColor.color(index, base: account.color)).frame(width: 6, height: 6)
                                Text(account.readings(settings: settings)[index].title).font(.subheadline)
                            }
                            AccessibleFormPicker("Amounts", selection: direction(for: ring), options: [("Default", Optional<AmountDirection>.none)] + AmountDirection.allCases.map { ($0.title, Optional($0)) }).font(.caption)
                        }
                    }.onDelete { settings.rings.remove(atOffsets: $0) }.onMove { settings.rings.move(fromOffsets: $0, toOffset: $1) }
                } header: { HStack { Text("Rings"); Spacer(); EditButton() } } footer: { Text("Up to four rings, outside to inside. Compact bars use the same metrics.") }
                Section("Available metrics") {
                    ForEach(availableMetrics) { metric in metricToggle(metric.window, kind: metric.kind) }
                }
                }
                Section("Colour") {
                    if textSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Account colour")
                            ColorPicker("Account colour", selection: colorBinding, supportsOpacity: false).labelsHidden().accessibilityLabel("Account colour")
                        }
                    } else { ColorPicker("Account colour", selection: colorBinding, supportsOpacity: false) }
                    Button("Use provider colour") { colorHex = nil }
                }
                Section { Button("Reset display settings") { settings = account.defaultDisplay; colorHex = nil } }
            }.scrollContentBackground(.hidden).background(Theme.background)
                .navigationTitle("Display").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { var copy = account; copy.display = settings; copy.retainMetricNames(); copy.colorHex = colorHex; store.update(copy); dismiss() } }
                }
        }
    }
    @State private var colorHex: UInt32?
    private var colorBinding: Binding<Color> {
        Binding(get: { colorHex.map { Color(hex: $0) } ?? account.provider.color }, set: { colorHex = $0.hexRGB })
    }
    private struct AvailableMetric: Identifiable {
        var window: UsageWindow
        var kind: MetricKind
        var id: String { window.id + ":" + kind.rawValue }
    }
    private var availableMetrics: [AvailableMetric] {
        (account.snapshot?.windows ?? []).flatMap { window in
            [AvailableMetric(window: window, kind: .usage)] + (window.duration != nil && window.resetsAt != nil ? [AvailableMetric(window: window, kind: .time)] : [])
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
        return Button {
            if selected { settings.rings.removeAll { $0.id == ring.id } }
            else if settings.rings.count < 4 { var named = ring; named.windowTitle = window.title; settings.rings.append(named) }
        } label: {
            HStack {
                Text(window.title + (kind == .time ? " time" : " usage")).foregroundStyle(.primary)
                Spacer()
                Image(systemName: selected ? "checkmark.square.fill" : "square").foregroundStyle(selected ? Theme.accent : .secondary)
            }.contentShape(Rectangle())
        }.buttonStyle(.borderless).disabled(!selected && settings.rings.count >= 4).accessibilityValue(selected ? "On" : "Off").accessibilityIdentifier("metric-\(ring.id)")
    }
}
