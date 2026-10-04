import Foundation
import SwiftUI

struct AccountEvent: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case weeklyReset, earlyReset, bankedDetected, bankedUsed, bankedExpired, bankedRemoved, parsingFailure, allowanceChanged, activationSent, windowStarted
        var title: String {
            switch self {
            case .weeklyReset: return "Weekly reset"
            case .earlyReset: return "Early reset"
            case .bankedDetected: return "Banked reset detected"
            case .bankedUsed: return "Banked reset used"
            case .bankedExpired: return "Banked reset expired"
            case .bankedRemoved: return "Banked reset removed"
            case .parsingFailure: return "Usage response changed"
            case .allowanceChanged: return "Plan or allowance changed"
            case .activationSent: return "Activation request completed"
            case .windowStarted: return "Weekly window started"
            }
        }
        var symbol: String {
            switch self {
            case .weeklyReset, .earlyReset: return "arrow.counterclockwise"
            case .bankedDetected: return "plus.circle"
            case .bankedUsed: return "checkmark.circle"
            case .bankedExpired, .bankedRemoved: return "minus.circle"
            case .parsingFailure: return "exclamationmark.triangle"
            case .allowanceChanged: return "arrow.up.arrow.down"
            case .activationSent: return "paperplane"
            case .windowStarted: return "play.circle"
            }
        }
    }
    var id: String
    var accountID: UUID
    var kind: Kind
    var date: Date
    var detectedAt: Date
    var window: String?
    var windowID: String?
    var previousPlan: String?
    var plan: String?
    var count: Int?
    var inferred = false
    var detail: String {
        let planChange: String?
        if let previousPlan, let plan, previousPlan != plan { planChange = previousPlan + " → " + plan } else { planChange = nil }
        return [window, planChange, count.map { "\($0) reset\($0 == 1 ? "" : "s")" }, inferred ? "Inferred from usage" : nil].compactMap { $0 }.joined(separator: " · ")
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
        func event(_ kind: AccountEvent.Kind, key: String, date: Date? = nil, window: String? = nil, windowID: String? = nil, count: Int? = nil, inferred: Bool = false) {
            events.append(AccountEvent(id: "\(accountID):\(kind.rawValue):\(key)", accountID: accountID, kind: kind, date: date ?? now, detectedAt: now, window: window, windowID: windowID, count: count, inferred: inferred))
        }
        let chronological = previous.map { now > $0.updatedAt } ?? true
        guard chronological else { return Result(snapshot: current, events: []) }
        let allowanceChanged = previous.map { AllowanceChanges.snapshotChanged($0, current) } ?? false
        if allowanceChanged { events.append(AccountEvent(id: "\(accountID):allowance:\(now.timeIntervalSince1970)", accountID: accountID, kind: .allowanceChanged, date: now, detectedAt: now, previousPlan: previous?.plan, plan: current.plan)) }
        var usedGrants: [(ResetGrant, Int)] = []
        if let old = previous?.resetInventory, let new = current.resetInventory, new.checkedAt > old.checkedAt {
            for grant in new.grants {
                guard let before = old.grants.first(where: { $0.id == grant.id }), before.remaining > grant.remaining,
                      !before.paused, !grant.paused, before.total == grant.total,
                      grant.expiresAt.map({ $0 > now }) ?? true else { continue }
                usedGrants.append((grant, before.remaining - grant.remaining))
            }
        }
        let confirmedUse = usedGrants.reduce(0) { $0 + $1.1 }
        var early = false
        for window in current.windows {
            if allowanceChanged { continue }
            guard let old = previous?.windows.first(where: { $0.id == window.id }) else { continue }
            if weekly(window), let reset = old.resetsAt, reset <= now,
               let next = window.resetsAt, next > reset {
                event(.weeklyReset, key: window.id + "-" + String(reset.timeIntervalSince1970), date: reset, window: window.title, windowID: window.id)
            } else if let reset = old.resetsAt, reset > now.addingTimeInterval(300),
                      (usedGrants.contains { $0.0.windowIDs.contains(window.id) } || significantDrop(old, window)) {
                early = true
                event(.earlyReset, key: window.id + "-" + String(now.timeIntervalSince1970), window: window.title, windowID: window.id, inferred: confirmedUse == 0)
            }
        }
        if confirmedUse > 0 {
            event(.bankedUsed, key: String(now.timeIntervalSince1970), count: confirmedUse)
        }
        if var inventory = snapshot.resetInventory {
            for index in inventory.grants.indices {
                inventory.grants[index].firstDetectedAt = previous?.resetInventory?.grants.first(where: { $0.id == inventory.grants[index].id })?.firstDetectedAt ?? now
            }
            snapshot.resetInventory = inventory
        }
        if var resets = snapshot.bankedResets {
            let old = previous?.bankedResets
            for index in resets.indices {
                let matching = old?.first { $0.id == resets[index].id }
                    ?? old?.first { $0.title == resets[index].title && $0.expiresAt == resets[index].expiresAt }
                resets[index].firstDetectedAt = matching?.firstDetectedAt ?? matching.map { _ in previous!.updatedAt }
                    ?? snapshot.resetInventory?.grants.first(where: { $0.id == resets[index].id })?.firstDetectedAt ?? now
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
                // The provider's grant counter takes precedence over usage inference.
                // Pause/surface/eligibility changes must not masquerade as redemption.
                if removed > 0 && current.resetInventory == nil {
                    event(early ? .bankedUsed : .bankedRemoved, key: String(now.timeIntervalSince1970), count: removed, inferred: early)
                }
            } else if after > (before ?? 0) {
                event(.bankedDetected, key: String(now.timeIntervalSince1970), count: after - (before ?? 0))
            }
            snapshot.bankedResets = resets
        }
        if current.resetInventory == nil, let known = previous?.resetInventory {
            for item in previous?.bankedResets ?? [] where item.expiresAt.map({ $0 <= now }) == true {
                event(.bankedExpired, key: item.id + "-" + String(item.expiresAt!.timeIntervalSince1970), date: item.expiresAt, count: item.count)
            }
            snapshot.resetInventory = known
            snapshot.bankedResets = previous?.bankedResets?.filter { $0.expiresAt.map { $0 > now } ?? true }
        }
        return Result(snapshot: snapshot, events: events)
    }
    private static func significantDrop(_ before: UsageWindow, _ after: UsageWindow) -> Bool {
        guard let old = before.safePercent, let new = after.safePercent else { return false }
        // A reset can already have accrued new use by the next reading. Keep a
        // substantial drop requirement so small provider corrections are ignored.
        return old >= 5 && old - new >= 5 && new <= max(1, old / 2)
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
