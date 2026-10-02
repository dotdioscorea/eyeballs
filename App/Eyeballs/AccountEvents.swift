import Foundation
import SwiftUI

struct AccountEvent: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case weeklyReset, earlyReset, bankedDetected, bankedUsed, bankedExpired, bankedRemoved, parsingFailure
        var title: String {
            switch self {
            case .weeklyReset: return "Weekly reset"
            case .earlyReset: return "Early reset"
            case .bankedDetected: return "Banked reset detected"
            case .bankedUsed: return "Banked reset used"
            case .bankedExpired: return "Banked reset expired"
            case .bankedRemoved: return "Banked reset removed"
            case .parsingFailure: return "Usage response changed"
            }
        }
        var symbol: String {
            switch self {
            case .weeklyReset, .earlyReset: return "arrow.counterclockwise"
            case .bankedDetected: return "plus.circle"
            case .bankedUsed: return "checkmark.circle"
            case .bankedExpired, .bankedRemoved: return "minus.circle"
            case .parsingFailure: return "exclamationmark.triangle"
            }
        }
    }
    var id: String
    var accountID: UUID
    var kind: Kind
    var date: Date
    var detectedAt: Date
    var window: String?
    var count: Int?
    var inferred = false
    var detail: String {
        [window, count.map { "\($0) reset\($0 == 1 ? "" : "s")" }, inferred ? "Inferred from usage" : nil].compactMap { $0 }.joined(separator: " · ")
    }
}

enum EventDetection {
    struct Result { var snapshot: UsageSnapshot; var events: [AccountEvent] }
    static func weekly(_ window: UsageWindow) -> Bool {
        window.duration.map { abs($0 - 604800) < 60 } == true || window.title.localizedCaseInsensitiveContains("weekly")
    }
    static func compare(accountID: UUID, previous: UsageSnapshot?, current: UsageSnapshot) -> Result {
        var snapshot = current
        let now = current.updatedAt
        var events: [AccountEvent] = []
        func event(_ kind: AccountEvent.Kind, key: String, date: Date? = nil, window: String? = nil, count: Int? = nil, inferred: Bool = false) {
            events.append(AccountEvent(id: "\(accountID):\(kind.rawValue):\(key)", accountID: accountID, kind: kind, date: date ?? now, detectedAt: now, window: window, count: count, inferred: inferred))
        }
        let chronological = previous.map { now > $0.updatedAt } ?? true
        guard chronological else { return Result(snapshot: current, events: []) }
        var early = false
        for window in current.windows {
            guard let old = previous?.windows.first(where: { $0.id == window.id }) else { continue }
            if weekly(window), let reset = old.resetsAt, reset <= now,
               let next = window.resetsAt, next > reset {
                event(.weeklyReset, key: window.id + "-" + String(reset.timeIntervalSince1970), date: reset, window: window.title)
            } else if let reset = old.resetsAt, reset > now.addingTimeInterval(300),
                      let before = old.safePercent, let after = window.safePercent, before >= 5, after <= 1, before - after >= 5 {
                early = true
                event(.earlyReset, key: window.id + "-" + String(now.timeIntervalSince1970), window: window.title, inferred: true)
            }
        }
        if var resets = snapshot.bankedResets {
            let old = previous?.bankedResets
            for index in resets.indices {
                let matching = old?.first { $0.id == resets[index].id }
                    ?? old?.first { $0.title == resets[index].title && $0.expiresAt == resets[index].expiresAt }
                resets[index].firstDetectedAt = matching?.firstDetectedAt ?? matching.map { _ in previous!.updatedAt } ?? now
                if let expiry = resets[index].expiresAt, expiry <= now {
                    event(.bankedExpired, key: resets[index].id + "-" + String(expiry.timeIntervalSince1970), date: expiry, count: resets[index].count)
                }
            }
            let before = old?.reduce(0) { $0 + max(0, $1.count) }
            let after = resets.reduce(0) { $0 + max(0, $1.count) }
            if let before, after < before {
                let missing = old!.filter { item in !resets.contains(where: { $0.id == item.id }) }
                let expired = min(before - after, missing.filter { $0.expiresAt.map { $0 <= now } == true }.reduce(0) { $0 + max(0, $1.count) })
                for item in missing where item.expiresAt.map({ $0 <= now }) == true {
                    event(.bankedExpired, key: item.id + "-" + String(item.expiresAt!.timeIntervalSince1970), date: item.expiresAt, count: item.count)
                }
                let removed = before - after - expired
                if removed > 0 { event(early ? .bankedUsed : .bankedRemoved, key: String(now.timeIntervalSince1970), count: removed, inferred: early) }
            } else if after > (before ?? 0) {
                event(.bankedDetected, key: String(now.timeIntervalSince1970), count: after - (before ?? 0))
            }
            snapshot.bankedResets = resets
        }
        return Result(snapshot: snapshot, events: events)
    }
}

struct AccountEventFile {
    let location: URL
    func read(now: Date = .now) throws -> [AccountEvent] {
        guard FileManager.default.fileExists(atPath: location.path) else { return [] }
        guard let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 5_000_000 else { throw UsageError.invalidResponse }
        return try JSONDecoder().decode([AccountEvent].self, from: Data(contentsOf: location)).filter { $0.detectedAt > now.addingTimeInterval(-90 * 86400) }
    }
    func write(_ events: [AccountEvent]) throws {
        try FileManager.default.defaultProtectedDirectory(location.deletingLastPathComponent())
        try JSONEncoder().encode(events).write(to: location, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
extension FileManager {
    func defaultProtectedDirectory(_ url: URL) throws { try createDirectory(at: url, withIntermediateDirectories: true) }
}

struct EventsView: View {
    @EnvironmentObject private var store: AccountStore
    @State private var accountID: UUID?
    var body: some View {
        List {
            Section {
                Picker("Account", selection: $accountID) {
                    Text("All accounts").tag(Optional<UUID>.none)
                    ForEach(store.accounts) { Text($0.title).tag(Optional($0.id)) }
                }
            }
            if store.events.isEmpty { Text("No events recorded.").foregroundStyle(.secondary) }
            ForEach(store.events.filter { accountID == nil || $0.accountID == accountID }.sorted { $0.detectedAt > $1.detectedAt }) { event in
                if let account = store.accounts.first(where: { $0.id == event.accountID }) {
                    NavigationLink { AccountDetailView(id: account.id) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: event.kind.symbol).foregroundStyle(account.color).frame(width: 22)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.kind.title).font(.subheadline.weight(.medium))
                                Text(account.title + (event.detail.isEmpty ? "" : " · " + event.detail)).font(.caption).foregroundStyle(.secondary)
                                Text(event.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }.scrollContentBackground(.hidden).background(Theme.background).navigationTitle("Events")
            .refreshable { await store.refreshAll() }
    }
}
