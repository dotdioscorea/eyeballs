import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AccountStore
    var body: some View {
        List {
            Section {
                Toggle("Notifications", isOn: Binding(get: { store.notificationsEnabled }, set: { value in Task { await store.enableNotifications(value) } }))
                if store.notificationsEnabled { NavigationLink("Notification settings") { NotificationSettingsView() } }
            }
            Section {
                NavigationLink("Privacy & storage") { PrivacyView() }
                Link("Source code", destination: URL(string: "https://github.com/dotdioscorea/eyeballs")!)
                NavigationLink("Report a problem") { ProblemReportView() }
            }
            Section { LabeledContent("Version", value: Diagnostics.version) }
        }.scrollContentBackground(.hidden).background(Theme.background).navigationTitle("Settings")
    }
}
struct PrivacyView: View {
    @State private var cleared = false
    var body: some View {
        List {
            Section {
                Text("Sign-in uses the iOS system browser. Tokens are stored in this iPhone’s Keychain and don’t sync to iCloud. Eyeballs doesn’t store passwords.")
                Text("Usage history is kept for up to 90 days. Account names and notes are stored on this device. Widgets receive names and usage, without emails, identities, notes or tokens.")
                Text("Requests go directly to provider APIs. Eyeballs has no backend, ads or analytics.")
                Text("Removing an account deletes its local tokens and saved data.")
            }
            Section {
                Text("Diagnostic events record sign-in stages, error categories, HTTP status codes and known usage field types for up to seven days. They exclude credentials and account identities. Nothing is sent automatically.")
                Button(cleared ? "Diagnostics cleared" : "Clear diagnostics") { Diagnostics.clear(); cleared = true }.disabled(cleared)
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
        let body = String(details.prefix(6000)) + "\n\nApp: \(Diagnostics.version)\niOS: \(UIDevice.current.systemVersion)" + (includeDebug ? "\n\nAttach eyeballs-debug.json here." : "")
        url.queryItems = [URLQueryItem(name: "title", value: String(title.prefix(160))), URLQueryItem(name: "body", value: body)]
        if let url = url.url { openURL(url) }
    }
}

struct NotificationSettingsView: View {
    @EnvironmentObject private var store: AccountStore
    var body: some View {
        Form {
            Section("Resets") {
                Toggle("Weekly reset", isOn: $store.notificationRules.weeklyReset)
                Toggle("Detected early reset", isOn: $store.notificationRules.earlyReset)
                Toggle("Banked reset changes", isOn: $store.notificationRules.bankedChanges)
                Toggle("Banked reset expiry", isOn: $store.notificationRules.bankedExpiry)
                if store.notificationRules.bankedExpiry {
                    Picker("Expiry warning", selection: $store.notificationRules.bankedExpiryHours) {
                        ForEach([1, 6, 12, 24, 48, 72], id: \.self) { Text("\($0)h before").tag($0) }
                    }
                }
            }
            Section("Allowance reminder") {
                Toggle("Before weekly reset", isOn: $store.notificationRules.allowanceReminder)
                if store.notificationRules.allowanceReminder {
                    Picker("Notify", selection: $store.notificationRules.allowanceHours) {
                        ForEach([1, 6, 12, 24, 48, 72], id: \.self) { Text("\($0)h before").tag($0) }
                    }
                    Stepper("At least \(store.notificationRules.minimumRemaining)% remaining", value: $store.notificationRules.minimumRemaining, in: 0...100, step: 5)
                }
            }
            Section { Toggle("Usage parsing failures", isOn: $store.notificationRules.parsingFailures) }
        }.scrollContentBackground(.hidden).background(Theme.background).navigationTitle("Notifications").navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
            .onChange(of: store.notificationRules) { _, _ in store.saveNotificationRules() }
    }
}
