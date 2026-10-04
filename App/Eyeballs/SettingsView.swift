import SwiftUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var session: AccountSession
    var body: some View {
        List {
            Section {
                NavigationLink { NotificationSettingsView() } label: { LabeledContent("Notifications", value: store.notificationsEnabled ? "On" : "Off") }.accessibilityIdentifier("notification-settings")
            }
            Section {
                NavigationLink("Updates") { UpdateSettingsView() }
                NavigationLink("Privacy & storage") { PrivacyView() }
                Link("Source code", destination: URL(string: "https://github.com/dotdioscorea/eyeballs")!)
                NavigationLink("Report a problem") { ProblemReportView() }
            }
            Section {
                if store.isDemo {
                    Button("Reset sample data") { store.resetDemo() }
                    Button("Simulate early reset") { store.simulateDemoReset() }
                    Button("Test notification") { Task { await session.testNotification() } }
                    Button("Exit demo") { session.endDemo() }
                } else {
                    Button("Demo") { session.startDemo() }.accessibilityIdentifier("start-demo")
                }
            } footer: { Text(store.isDemo ? "Sample accounts use separate storage and make no provider requests." : "Explore with sample accounts.") }
            Section { LabeledContent("Version", value: Diagnostics.version) }
        }.scrollContentBackground(.hidden).background(Theme.background).navigationTitle("Settings")
    }
}

struct UpdateSettingsView: View {
    @AppStorage("foreground-refresh-minutes") private var interval = 1
    @Environment(\.scenePhase) private var phase
    @Environment(\.openURL) private var openURL
    @State private var status = RefreshSettings.backgroundStatus
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    var body: some View {
        List {
            Section {
                Picker("While app is open", selection: $interval) {
                    ForEach(RefreshSettings.intervals, id: \.self) { Text("Every \($0) min").tag($0) }
                }
            }
            Section {
                LabeledContent("Background App Refresh", value: status)
                if lowPower { LabeledContent("Low Power Mode", value: "On") }
                if status != "Available", !lowPower { Button("Open iPhone settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) } }
            } footer: { Text("Background timing is set by iOS. Widgets can request updates but don’t keep the app running.") }
        }.scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle("Updates").navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
            .onChange(of: phase) { _, _ in status = RefreshSettings.backgroundStatus; lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled }
    }
}
struct PrivacyView: View {
    @State private var cleared = false
    var body: some View {
        List {
            Section {
                Text("Sign-in uses the iOS system browser or Perplexity’s email codes. Tokens are stored in this iPhone’s Keychain and don’t sync to iCloud. Requota doesn’t store passwords or email codes.")
                Text("Usage history is kept for up to 90 days. Account names and notes are stored on this device. Widgets receive names and usage, without emails, identities, notes or tokens.")
                Text("Requests go directly to provider APIs. Requota has no backend, ads or analytics.")
                Text("Removing an account deletes its local tokens and saved data.")
            }
            Section {
                Text("Diagnostic events record sign-in stages, error categories, HTTP status codes and known usage field types for up to seven days. They exclude credentials and account identities. Nothing is sent automatically.")
                Button(cleared ? "Diagnostics cleared" : "Clear diagnostics") { Diagnostics.clear(); cleared = true }.disabled(cleared)
            }
            Section {
                Link("Privacy policy", destination: URL(string: "https://dotdioscorea.github.io/eyeballs/")!)
            }
        }.font(.subheadline).scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle("Privacy & storage").navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
    }
}
struct ProblemReportView: View {
    @EnvironmentObject private var store: AccountStore
    @Environment(\.openURL) private var openURL
    @State private var title: String
    @State private var details: String
    @State private var includeDebug: Bool
    @State private var debugFile: URL?
    @State private var debugText = ""
    @State private var exportError: String?
    init(title: String = "", details: String = "", includeDebug: Bool = false) {
        _title = State(initialValue: title); _details = State(initialValue: details); _includeDebug = State(initialValue: includeDebug)
    }
    var body: some View {
        Form {
            Section {
                TextField("Problem summary", text: $title)
                TextField("What happened?", text: $details, axis: .vertical).lineLimit(5...12)
            }
            Section {
                Toggle("Include debug bundle", isOn: $includeDebug).accessibilityIdentifier("include-debug-bundle")
                if includeDebug {
                    if let debugFile { ShareLink("Save or share debug bundle", item: debugFile) }
                    DisclosureGroup("View debug bundle") { Text(debugText).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    if let exportError { Text(exportError).foregroundStyle(.orange) }
                }
            } footer: { Text(includeDebug ? "Save the JSON file, then attach it to your GitHub issue. It excludes tokens, names, emails and notes." : "A debug bundle can help diagnose sign-in and widget problems.") }
            Section {
                Button("Open GitHub issue") { openIssue() }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } footer: { Text("GitHub issues are public. Review your report before submitting.") }
        }.scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle("Report a problem").navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
            .onAppear { if includeDebug { prepareDebug() } }
            .onChange(of: includeDebug) { _, enabled in if enabled { prepareDebug() } }
    }
    private func prepareDebug() {
        do {
            let data = try Diagnostics.encode(Diagnostics.bundle(accounts: store.accounts))
            debugText = String(decoding: data, as: UTF8.self); debugFile = try Diagnostics.export(data); exportError = nil
        } catch { exportError = "Could not create the debug bundle." }
    }
    private func openIssue() {
        var url = URLComponents(string: "https://github.com/dotdioscorea/eyeballs/issues/new")!
        let body = String(details.prefix(6000)) + "\n\nApp: \(Diagnostics.version)\niOS: \(UIDevice.current.systemVersion)" + (includeDebug ? "\n\nAttach requota-debug.json here." : "")
        url.queryItems = [URLQueryItem(name: "title", value: String(title.prefix(160))), URLQueryItem(name: "body", value: body)]
        if let url = url.url { openURL(url) }
    }
}

struct NotificationSettingsView: View {
    @EnvironmentObject private var store: AccountStore
    @Environment(\.scenePhase) private var phase
    @Environment(\.openURL) private var openURL
    @State private var status = NotificationDeliveryStatus.saved
    @State private var testMessage: String?
    private var providers: [Provider] { Provider.allCases.filter { provider in store.accounts.contains { $0.provider == provider } } }
    var body: some View {
        Form {
            Section {
                Toggle("Enable notifications", isOn: Binding(get: { store.notificationsEnabled }, set: { value in Task { await store.enableNotifications(value); await reload() } })).accessibilityIdentifier("notifications-enabled")
                LabeledContent("iOS permission", value: status.authorization)
                LabeledContent("Alerts", value: status.alerts)
                LabeledContent("Scheduled reminders", value: String(status.scheduled))
                Button("Open iPhone settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                Button("Test notification") { Task {
                    do { try await NotificationDelivery.shared.test(); testMessage = "Test scheduled for 3 seconds from now." }
                    catch { testMessage = "Could not schedule the test." }
                } }.disabled(!store.notificationsEnabled || status.authorization == "Denied")
                if let testMessage { Text(testMessage).font(.caption).foregroundStyle(.secondary) }
                if status.schedulingFailed { Text("Some reminders could not be scheduled. Try enabling notifications again.").font(.caption).foregroundStyle(.orange) }
            } footer: { Text("Reset reminders can arrive while the app is closed. Low usage and early resets need a successful refresh. Focus and iOS notification settings can delay alerts.") }
            NotificationRuleControls(rules: $store.notificationRules)
            if !providers.isEmpty {
                Section("Providers") {
                    ForEach(providers) { provider in
                        NavigationLink { ProviderNotificationSettings(provider: provider) } label: {
                            LabeledContent(provider.name, value: store.notificationProviderRules[provider.rawValue].map { $0.enabled ? "Custom" : "Off" } ?? "Default")
                        }
                    }
                }
            }
        }.scrollContentBackground(.hidden).background(Theme.background).navigationTitle("Notifications").navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
            .task { await reload() }
            .onChange(of: phase) { _, value in if value == .active { Task { await reload() } } }
            .onChange(of: store.notificationRules) { _, _ in store.saveNotificationRules(); Task { await reload() } }
            .onChange(of: store.notificationProviderRules) { _, _ in store.saveNotificationRules(); Task { await reload() } }
    }
    private func reload() async { await store.scheduleNotifications(); status = await NotificationDelivery.shared.status() }
}
struct ProviderNotificationSettings: View {
    let provider: Provider
    @EnvironmentObject private var store: AccountStore
    private var custom: Bool { store.notificationProviderRules[provider.rawValue] != nil }
    private var rules: Binding<ResetNotificationRules> {
        Binding(get: { store.notificationProviderRules[provider.rawValue] ?? store.notificationRules }, set: { store.notificationProviderRules[provider.rawValue] = $0 })
    }
    var body: some View {
        Form {
            Section {
                Toggle("Use default settings", isOn: Binding(get: { !custom }, set: { defaults in
                    if defaults { store.notificationProviderRules.removeValue(forKey: provider.rawValue) }
                    else { store.notificationProviderRules[provider.rawValue] = store.notificationRules }
                }))
                if custom { Toggle("Notify for this provider", isOn: rules.enabled) }
            }
            if custom, rules.wrappedValue.enabled { NotificationRuleControls(rules: rules) }
        }.scrollContentBackground(.hidden).background(Theme.background).navigationTitle(provider.name).navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
            .onChange(of: store.notificationProviderRules) { _, _ in store.saveNotificationRules() }
    }
}
struct NotificationRuleControls: View {
    @Binding var rules: ResetNotificationRules
    var body: some View {
        Section("Low allowance") {
            Toggle("Low remaining allowance", isOn: $rules.lowAllowance)
            if rules.lowAllowance {
                Picker("Remaining threshold", selection: $rules.lowThreshold) { ForEach([0, 5, 10, 15, 20, 25, 50], id: \.self) { Text("\($0)%").tag($0) } }
            }
        }
        Section("Resets") {
            Toggle("Weekly reset", isOn: $rules.weeklyReset)
            Toggle("Other window resets", isOn: $rules.sessionReset)
            Toggle("Detected early reset", isOn: $rules.earlyReset)
            Toggle("Banked reset changes", isOn: $rules.bankedChanges)
            Toggle("Banked reset expiry", isOn: $rules.bankedExpiry)
            if rules.bankedExpiry {
                Picker("Expiry warning", selection: $rules.bankedExpiryHours) { ForEach([1, 6, 12, 24, 48, 72], id: \.self) { Text("\($0)h before").tag($0) } }
            }
        }
        Section("Before weekly reset") {
            Toggle("Unused allowance reminder", isOn: $rules.allowanceReminder)
            if rules.allowanceReminder {
                Picker("Notify", selection: $rules.allowanceHours) { ForEach([1, 6, 12, 24, 48, 72], id: \.self) { Text("\($0)h before").tag($0) } }
                Stepper("At least \(rules.minimumRemaining)% remaining", value: $rules.minimumRemaining, in: 0...100, step: 5)
            }
        }
        Section("Account changes") {
            Toggle("Plan or allowance changes", isOn: $rules.allowanceChanges)
            Toggle("Usage parsing failures", isOn: $rules.parsingFailures)
        }
    }
}
