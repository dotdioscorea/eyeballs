import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AccountStore
    var body: some View {
        List {
            Section {
                HStack(spacing: 18) {
                    EyeballsMark(size: 56)
                    VStack(alignment: .leading, spacing: 5) { Text("Eyeballs").font(.title3.weight(.semibold)); Text("A little clarity for your AI accounts.").font(.caption).foregroundStyle(.secondary) }
                }.padding(.vertical, 8)
            }
            Section {
                Toggle("Reset reminders", isOn: Binding(get: { store.notificationsEnabled }, set: { value in Task { await store.enableNotifications(value) } })).disabled(store.isDemo)
            } header: { Text("Notifications") } footer: { Text("A quiet reminder when a provider-reported reset is due. Usage is confirmed on the next refresh.") }
            Section {
                NavigationLink("Add a widget") { WidgetGuideView() }
                NavigationLink("Privacy & storage") { PrivacyView() }
            }
            Section {
                Button(store.isDemo ? "Exit preview" : "Preview with sample accounts") { store.isDemo ? store.endDemo() : store.startDemo() }
            } footer: { Text("Preview accounts use sample data and never replace your saved connections.") }
            Section {
                LabeledContent("Version", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"))")
            }
        }.scrollContentBackground(.hidden).background(Theme.background).navigationTitle("Settings")
    }
}

struct WidgetGuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("A glance is enough.").font(.system(size: 32, weight: .semibold)).tracking(-1)
                HStack(spacing: 25) {
                    ForEach(DemoAccounts.accounts) { account in
                        VStack(spacing: 12) { UsageRing(windows: account.snapshot!.windows, color: account.provider.color, size: 76, lineWidth: 6); Text(account.provider.name).font(.caption.weight(.medium)) }
                    }
                }.frame(maxWidth: .infinity).panel()
                Text("Sample widget layout").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(["Touch and hold your Home Screen, then choose Edit → Add Widget.", "Search for Eyeballs and choose an account or the overview.", "Touch and hold an account widget, then choose Edit Widget to pick its account."].enumerated()), id: \.offset) { index, instruction in
                    HStack(alignment: .top, spacing: 16) { Text("\(index + 1)").font(.headline).foregroundStyle(Theme.accent).frame(width: 24); Text(instruction).font(.subheadline).foregroundStyle(.secondary) }
                }
                Text("Widgets show your latest saved reading. iOS decides when widgets refresh; opening Eyeballs updates them. Account credentials never go to widgets.").font(.caption).foregroundStyle(.secondary).panel()
            }.padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Widgets").navigationBarTitleDisplayMode(.inline)
    }
}

struct PrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "lock.shield").font(.system(size: 48)).foregroundStyle(Theme.accent)
                Text("Your accounts.\nYour iPhone.").font(.system(size: 34, weight: .semibold)).tracking(-1)
                paragraph("Credentials stay local", "Sign-in uses the provider’s OAuth flow in the iOS system browser. Each account has separate credentials in this iPhone’s Keychain, without syncing them to other devices. Eyeballs never asks for or stores your password.")
                paragraph("Only what you need", "The app requests usage and reset information directly from provider APIs. Usage summaries, names and your notes are saved on this device. Widgets receive account labels and usage snapshots, without email addresses, private notes or credentials.")
                paragraph("No tracking backend", "Eyeballs has no account system, advertising, analytics SDK or server collecting your usage. Requests go directly from your iPhone to the provider. Provider websites and their sign-in services follow their own privacy policies.")
                paragraph("You’re in control", "Remove a connection to clear its credentials, account information and widget summary. Other connections remain in place. Eyeballs also attempts to revoke its own renewable ChatGPT session; if this cannot be confirmed, you can disconnect it in ChatGPT settings.")
                paragraph("About usage readings", "Subscription usage comes from provider-controlled interfaces, which can change. Missing readings are shown as unavailable. Cached readings stay visible with their timestamp; a predicted reset never overwrites them with zero.")
            }.padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Privacy").navigationBarTitleDisplayMode(.inline)
    }
    private func paragraph(_ title: String, _ text: String) -> some View { VStack(alignment: .leading, spacing: 8) { Text(title).font(.headline); Text(text).font(.subheadline).foregroundStyle(.secondary).lineSpacing(4) } }
}
