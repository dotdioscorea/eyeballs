import AppIntents
import Foundation

// App Intents may resolve widget parameters in either process. Compile the entity,
// query and configuration into both targets, using only the shared summary cache.
struct AccountEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Account"
    static var defaultQuery = AccountQuery()
    var id: String
    @Property(title: "Name") var title: String
    @Property(title: "Provider") var provider: String
    init(id: String, title: String, provider: String = "") { self.id = id; self.title = title; self.provider = provider }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)", subtitle: "\(provider)") }
}
struct AccountQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [AccountEntity] {
        Self.resolve(identifiers, accounts: WidgetCache.read())
    }
    func suggestedEntities() async throws -> [AccountEntity] { Self.values(WidgetCache.read()) }
    func entities(matching string: String) async throws -> [AccountEntity] {
        Self.values(WidgetCache.read()).filter { "\($0.title) \($0.provider)".localizedCaseInsensitiveContains(string) }
    }
    func defaultResult() async -> AccountEntity? { Self.values(WidgetCache.read()).first }
    static func values(_ accounts: [AgentAccount]) -> [AccountEntity] {
        AccountSort.name.sorted(accounts).map { AccountEntity(id: $0.id.uuidString, title: $0.title, provider: $0.provider.name) }
    }
    static func resolve(_ identifiers: [String], accounts: [AgentAccount]) -> [AccountEntity] {
        let values = self.values(accounts)
        var seen = Set<String>()
        return identifiers.compactMap { identifier in
            guard let id = UUID(uuidString: identifier)?.uuidString, seen.insert(id).inserted else { return nil }
            return values.first { $0.id == id }
        }
    }
}
enum WidgetAmount: String, AppEnum {
    case account, remaining, used
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Amounts"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.account: "Account settings", .remaining: "Remaining", .used: "Used / elapsed"]
}
enum WidgetMetrics: String, AppEnum {
    case account, sessionAndWeek, weekAndTime, week, session
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Metrics"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.account: "Account settings", .sessionAndWeek: "5-hour + weekly", .weekAndTime: "Weekly + weekly time", .week: "Weekly", .session: "5-hour"]
    func settings(for account: AgentAccount, amount: WidgetAmount) -> AccountDisplay {
        var settings = account.displaySettings
        if self != .account {
            let session = account.window(for: .session), week = account.window(for: .weekly)
            switch self {
            case .sessionAndWeek: settings.rings = [session, week].compactMap { $0 }.map { RingDefinition(windowID: $0.id) }
            case .weekAndTime: settings.rings = week.map { [RingDefinition(windowID: $0.id), RingDefinition(windowID: $0.id, kind: .time)] } ?? []
            case .week: settings.rings = week.map { [RingDefinition(windowID: $0.id)] } ?? []
            case .session: settings.rings = session.map { [RingDefinition(windowID: $0.id)] } ?? []
            case .account: break
            }
        }
        if amount != .account {
            settings.direction = amount == .remaining ? .remaining : .used
            settings.rings = settings.rings.map { var ring = $0; ring.direction = nil; return ring }
        }
        return settings
    }
}
enum WidgetLayout: String, AppEnum {
    case bars, rings
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Layout"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.bars: "Compact bars", .rings: "Rings"]
}
enum WidgetOrder: String, AppEnum {
    case selected, name, provider, mostRemaining, leastRemaining, weeklyRemaining, nextReset
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Sort"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.selected: "Selection order", .name: "Name", .provider: "Provider", .mostRemaining: "Most remaining", .leastRemaining: "Least remaining", .weeklyRemaining: "Weekly remaining", .nextReset: "Next reset"]
    func sorted(_ accounts: [AgentAccount]) -> [AgentAccount] {
        self == .selected ? accounts : (AccountSort(rawValue: rawValue) ?? .name).sorted(accounts)
    }
}
struct AccountIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Account"
    @Parameter(title: "Account") var account: AccountEntity?
    @Parameter(title: "Amounts", default: .account) var amount: WidgetAmount
    @Parameter(title: "Metrics", default: .account) var metrics: WidgetMetrics
}
struct OverviewIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Accounts"
    @Parameter(title: "Accounts") var accounts: [AccountEntity]?
    @Parameter(title: "Layout", default: .bars) var layout: WidgetLayout
    @Parameter(title: "Amounts", default: .account) var amount: WidgetAmount
    @Parameter(title: "Metrics", default: .account) var metrics: WidgetMetrics
    @Parameter(title: "Sort", default: .selected) var sort: WidgetOrder
}
