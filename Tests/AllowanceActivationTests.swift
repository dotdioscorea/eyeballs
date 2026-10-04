import XCTest
@testable import Requota

@MainActor
final class AllowanceActivationTests: XCTestCase {
    var directory: URL!
    override func setUp() { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }
    func unused(_ credential: AccountCredential, reset: Date? = nil, used: Double = 0, now: Date = .now) -> UsageSnapshot {
        UsageSnapshot(windows: [UsageWindow(id: credential.provider == .claude ? "seven_day" : "primary_window", title: "Weekly", usedPercent: used, resetsAt: reset, duration: 604800, clockReported: true)], plan: "Pro", identity: credential.registrationIdentity, updatedAt: now, includedUsageAllowed: true)
    }
    func claude() -> AccountCredential {
        var credential = Fixture.credential("claude"); credential.provider = .claude; credential.issuer = ProviderAuth.issuer(.claude); credential.clientID = ProviderAuth.claudeClientID; credential.scopes = ["user:profile", "user:inference"]; return credential
    }
    func testCandidateRequiresFreshKnownUnusedPersonalAllowance() {
        let credential = Fixture.credential("one"), now = Date.now
        let valid = unused(credential, now: now)
        XCTAssertTrue(AllowanceActivation.candidate(valid, provider: .codex, now: now))
        for mutation in [0, 1, 2, 3, 4, 5] {
            var invalid = valid
            switch mutation {
            case 0: invalid.updatedAt = now.addingTimeInterval(-121)
            case 1: invalid.windows[0].usedPercent = nil
            case 2: invalid.windows[0].usedPercent = 1
            case 3: invalid.windows[0].clockReported = nil
            case 4: invalid.plan = "Enterprise"
            default: invalid.windows[0].duration = 2592000
            }
            XCTAssertFalse(AllowanceActivation.candidate(invalid, provider: .codex, now: now), "Mutation \(mutation)")
        }
        XCTAssertFalse(AllowanceActivation.candidate(valid, provider: .grok, now: now))
        XCTAssertFalse(AllowanceActivation.candidate(unused(credential, reset: now.addingTimeInterval(3600), now: now), provider: .codex, now: now))
        XCTAssertTrue(AllowanceActivation.candidate(unused(credential, reset: now.addingTimeInterval(604800), now: now), provider: .codex, now: now))
        var busy = valid; busy.windows.append(UsageWindow(id: "secondary_window", title: "5 hour", usedPercent: 100, duration: 18000))
        XCTAssertFalse(AllowanceActivation.candidate(busy, provider: .codex, now: now))
        busy.windows[1].usedPercent = nil
        XCTAssertFalse(AllowanceActivation.candidate(busy, provider: .codex, now: now))
        var denied = valid; denied.includedUsageAllowed = false
        XCTAssertFalse(AllowanceActivation.candidate(denied, provider: .codex, now: now))
        denied.includedUsageAllowed = nil
        XCTAssertFalse(AllowanceActivation.candidate(denied, provider: .codex, now: now))
    }
    func testMissingOrMalformedResetFieldCannotEnableAutomaticConsumption() throws {
        for value in [nil, "unexpected", true] as [Any?] {
            var raw: [String: Any] = ["used_percent": 0, "limit_window_seconds": 604800]
            if let value { raw["reset_at"] = value }
            let snapshot = try UsageParser.codex(["plan_type": "pro", "rate_limit": ["allowed": true, "primary_window": raw]])
            XCTAssertFalse(AllowanceActivation.candidate(snapshot, provider: .codex))
        }
        let valid = try UsageParser.codex(["plan_type": "pro", "rate_limit": ["allowed": true, "primary_window": ["used_percent": 0, "limit_window_seconds": 604800, "reset_at": NSNull()]]])
        XCTAssertTrue(AllowanceActivation.candidate(valid, provider: .codex))
        XCTAssertFalse(UsageParser.clockReported(-1))
    }
    func testInactiveCodexSecondaryWindowDoesNotBecomeAnUnknownAllowance() throws {
        let primary: [String: Any] = ["used_percent": 0, "limit_window_seconds": 604800, "reset_at": NSNull()]
        let inactive = try UsageParser.codex(["plan_type": "pro", "rate_limit": ["allowed": true, "primary_window": primary, "secondary_window": [:]]])
        XCTAssertEqual(inactive.windows.count, 1)
        XCTAssertTrue(AllowanceActivation.candidate(inactive, provider: .codex))
        let unknown = try UsageParser.codex(["plan_type": "pro", "rate_limit": ["allowed": true, "primary_window": primary, "secondary_window": ["limit_window_seconds": 18000]]])
        XCTAssertFalse(AllowanceActivation.candidate(unknown, provider: .codex))
    }
    func testReadOnlyClaudeAndOtherRegistrationsCannotInfer() {
        var credential = claude()
        XCTAssertTrue(AllowanceActivation.permitted(credential))
        credential.scopes = ["user:profile"]
        XCTAssertFalse(AllowanceActivation.permitted(credential))
        XCTAssertEqual(ProviderAuth.authorizationScopes(.claude), "user:profile")
        XCTAssertEqual(ProviderAuth.authorizationScopes(.claude, allowActivation: true), "user:profile user:inference")
        XCTAssertEqual(ProviderAuth.authorizationScopes(.claude, previous: claude()), "user:profile user:inference")
        var codex = Fixture.credential("two"); codex.clientID = "oaiapp_other"
        XCTAssertFalse(AllowanceActivation.permitted(codex))
        codex.clientID = OpenAIAuth.codexClientID; codex.accessToken = ""
        XCTAssertFalse(AllowanceActivation.permitted(codex))
        codex.accessToken = "fixture"; codex.accountID = nil
        XCTAssertFalse(AllowanceActivation.permitted(codex))
    }
    func testClaudeActivationIsExplicitInOAuthAndRetainedOnReconnect() throws {
        let callback = URL(string: "http://localhost:12345/callback")!
        for (enabled, previous) in [(false, nil), (true, nil), (false, Optional(claude()))] {
            let attempt = try OAuthAttempt(redirectURI: callback, hostID: "test", previous: previous, provider: .claude, allowActivation: enabled)
            let scope = URLComponents(url: attempt.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "scope" }!.value!
            XCTAssertEqual(scope.contains("user:inference"), enabled || previous != nil)
        }
    }
    func testMovingDeadlineAndUncertainAttemptsDoNotRepeatWithinWeek() {
        let now = Date.now, credential = Fixture.credential("one")
        let snapshot = unused(credential, reset: now.addingTimeInterval(604800), now: now)
        for status in [ActivationRecord.Status.attempted, .completed, .started, .failed] {
            let record = ActivationRecord(attemptedAt: now.addingTimeInterval(-86400), status: status)
            XCTAssertFalse(AllowanceActivation.mayAutomaticallyAttempt(snapshot, provider: .codex, record: record, now: now))
        }
        let expired = ActivationRecord(attemptedAt: now.addingTimeInterval(-604801), status: .completed)
        XCTAssertTrue(AllowanceActivation.mayAutomaticallyAttempt(snapshot, provider: .codex, record: expired, now: now))
        let usedThenReset = ActivationRecord(attemptedAt: now.addingTimeInterval(-3600), status: .completed, usedSinceAttempt: true, lastObservedUsed: 1)
        XCTAssertTrue(AllowanceActivation.mayAutomaticallyAttempt(snapshot, provider: .codex, record: usedThenReset, now: now))
        XCTAssertFalse(AllowanceActivation.mayAutomaticallyAttempt(unused(credential, reset: now.addingTimeInterval(3600), now: now), provider: .codex, record: usedThenReset, now: now))
    }
    func testConfirmedClockStartIsSeparateFromSuccessfulRequest() {
        let now = Date.now, credential = Fixture.credential("one"), deadline = now.addingTimeInterval(604800)
        var record = ActivationRecord(attemptedAt: now, status: .completed, resetAt: deadline,
            windowID: "primary_window", resetObservedAt: now, plan: "Pro")
        let first = unused(credential, reset: deadline, now: now)
        XCTAssertFalse(AllowanceActivation.confirmedStart(record: record, snapshot: first, provider: .codex, now: now))
        let later = now.addingTimeInterval(61)
        let stable = unused(credential, reset: deadline, now: later)
        XCTAssertTrue(AllowanceActivation.confirmedStart(record: record, snapshot: stable, provider: .codex, now: later))
        record.previousResetAt = deadline
        XCTAssertFalse(AllowanceActivation.confirmedStart(record: record, snapshot: stable, provider: .codex, now: later))
        record.previousResetAt = deadline.addingTimeInterval(-5)
        XCTAssertTrue(AllowanceActivation.confirmedStart(record: record, snapshot: stable, provider: .codex, now: later))
        XCTAssertFalse(AllowanceActivation.confirmedStart(record: record, snapshot: unused(credential, reset: later.addingTimeInterval(604800), now: later), provider: .codex, now: later), "Moving deadline is not a started clock")
        record.status = .failed
        XCTAssertFalse(AllowanceActivation.confirmedStart(record: record, snapshot: stable, provider: .codex, now: later))
        let c = claude(), claudeDeadline = now.addingTimeInterval(604800 + 2700)
        let claudeRecord = ActivationRecord(attemptedAt: now, status: .completed, resetAt: claudeDeadline, windowID: "seven_day", resetObservedAt: now, plan: "Pro")
        XCTAssertFalse(AllowanceActivation.confirmedStart(record: claudeRecord, snapshot: unused(c, reset: claudeDeadline, now: later), provider: .claude, now: later), "An hour-rounded moving deadline needs longer verification")
        let nextHour = now.addingTimeInterval(3661)
        XCTAssertTrue(AllowanceActivation.confirmedStart(record: claudeRecord, snapshot: unused(c, reset: claudeDeadline, now: nextHour), provider: .claude, now: nextHour))
    }
    func testClockConfirmationRejectsChangedPlanWindowAndStaleReadings() {
        let now = Date.now, credential = Fixture.credential("one"), deadline = now.addingTimeInterval(604800)
        let record = ActivationRecord(attemptedAt: now.addingTimeInterval(-120), status: .completed, resetAt: deadline,
            windowID: "primary_window", resetObservedAt: now.addingTimeInterval(-61), plan: "Pro", allowanceContext: "original-plan")
        var snapshot = unused(credential, reset: deadline, now: now); snapshot.allowanceContext = "original-plan"
        XCTAssertTrue(AllowanceActivation.confirmedStart(record: record, snapshot: snapshot, provider: .codex, now: now))
        snapshot.plan = "Plus"
        XCTAssertFalse(AllowanceActivation.confirmedStart(record: record, snapshot: snapshot, provider: .codex, now: now))
        snapshot.plan = "Pro"; snapshot.allowanceContext = "upgraded"
        XCTAssertFalse(AllowanceActivation.confirmedStart(record: record, snapshot: snapshot, provider: .codex, now: now))
        snapshot.allowanceContext = "original-plan"; snapshot.windows[0].id = "secondary_window"
        XCTAssertFalse(AllowanceActivation.confirmedStart(record: record, snapshot: snapshot, provider: .codex, now: now))
        snapshot.windows[0].id = "primary_window"; snapshot.updatedAt = now.addingTimeInterval(-121)
        XCTAssertFalse(AllowanceActivation.confirmedStart(record: record, snapshot: snapshot, provider: .codex, now: now))
    }
    func testStreamRequiresCompletedEventAndRejectsInStreamFailures() {
        func data(_ text: String) -> Data { Data(text.utf8) }
        XCTAssertFalse(AllowanceActivation.completedStream(data("data: [DONE]\n")))
        XCTAssertFalse(AllowanceActivation.completedStream(data("data: {\"type\":\"response.created\"}\n")))
        let complete = "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n"
        XCTAssertTrue(AllowanceActivation.completedStream(data(complete)))
        XCTAssertFalse(AllowanceActivation.completedStream(data(complete + "data: {\"type\":\"response.failed\"}\n")))
    }
    func testCodexUsesAccountScopedSubscriptionRouteWithoutToolsOrRetries() async throws {
        let credential = Fixture.credential("one"); var paths: [String] = []
        try await AllowanceActivation.send(credential) { request in
            paths.append(request.url!.path)
            XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), credential.accountID)
            XCTAssertEqual(request.value(forHTTPHeaderField: "originator"), "requota")
            let data: Data
            if request.httpMethod == "POST" {
                let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
                XCTAssertEqual(body["store"] as? Bool, false); XCTAssertEqual(body["stream"] as? Bool, true)
                XCTAssertEqual((body["tools"] as? [Any])?.count, 0); XCTAssertEqual(body["tool_choice"] as? String, "none")
                XCTAssertNil(body["service_tier"]); XCTAssertNil(body["max_output_tokens"])
                data = Data("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n".utf8)
            } else {
                data = try JSONSerialization.data(withJSONObject: ["models": [["slug": "gpt-6-luna", "visibility": "list", "supported_reasoning_levels": [["effort": "low"]]]]])
            }
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        XCTAssertEqual(paths, ["/backend-api/codex/models", "/backend-api/codex/responses"])
    }
    func testClaudeUsesGrantedScopeAndSmallBoundedMessage() async throws {
        var calls = 0
        try await AllowanceActivation.send(claude()) { request in
            calls += 1
            let object: [String: Any]
            if request.httpMethod == "POST" {
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                XCTAssertEqual(body["max_tokens"] as? Int, 8); XCTAssertNil(body["tools"])
                object = ["stop_reason": "end_turn"]
            } else { object = ["data": [["id": "claude-haiku-4-5-20251001"]]] }
            return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        XCTAssertEqual(calls, 2)
        var readonly = claude(); readonly.scopes = ["user:profile"]
        do { try await AllowanceActivation.send(readonly) { _ in XCTFail("No request with read-only token"); throw UsageError.unavailable }; XCTFail("Expected permission error") }
        catch ActivationError.permissionRequired { }
    }
    func testPreparationFailuresNeverPostAndMalformedModelsCanBeReported() async throws {
        let credential = Fixture.credential("one"); var calls = 0
        do {
            try await AllowanceActivation.send(credential) { request in
                calls += 1; XCTAssertNotEqual(request.httpMethod, "POST")
                return (Data("{\"new_schema\":[]}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            XCTFail("Expected a preparation error")
        } catch let failure as ActivationPreparationFailure {
            XCTAssertEqual(DiagnosticFailure.category(failure), .response)
            XCTAssertTrue(failure.localizedDescription.contains("No message was sent"))
        }
        XCTAssertEqual(calls, 1)
        let account = AgentAccount(provider: .codex, snapshot: unused(credential))
        let store = AccountStore(location: directory.appendingPathComponent("accounts.json"), vault: MemoryVault(), integratesWithSystem: false,
            fetcher: { _, c in self.unused(c) },
            activator: { _ in throw ActivationPreparationFailure(cause: UsageError.invalidResponse) })
        try store.connect(account, credential: credential)
        store.setAutomaticActivation(true, for: account.id)
        await store.refresh(account.id)
        XCTAssertEqual(store.accounts[0].needsReport, true)
        XCTAssertEqual(store.reportAccountID, account.id)
        XCTAssertEqual(store.events.filter { $0.kind == .parsingFailure }.count, 1)
        XCTAssertEqual(store.accounts[0].activation?.status, .failed)
        XCTAssertNotNil(store.accounts[0].activation?.retryAfter)
    }
    func testKnownUnsentFailureRetriesAfterBackoffAndSurvivesRelaunch() async throws {
        let path = directory.appendingPathComponent("accounts.json"), credential = Fixture.credential("one"), vault = MemoryVault(); var attempts = 0
        let account = AgentAccount(provider: .codex, snapshot: unused(credential))
        let store = AccountStore(location: path, vault: vault, integratesWithSystem: false, fetcher: { _, c in self.unused(c) }, activator: { _ in
            attempts += 1; throw ActivationPreparationFailure(cause: URLError(.timedOut))
        })
        try store.connect(account, credential: credential)
        store.setAutomaticActivation(true, for: account.id)
        await store.refresh(account.id); await store.refresh(account.id)
        XCTAssertEqual(attempts, 1); XCTAssertNotNil(store.accounts[0].activation?.retryAfter)
        var saved = store.accounts; saved[0].activation?.retryAfter = .now.addingTimeInterval(-1)
        try JSONEncoder().encode(saved).write(to: path, options: .atomic)
        let restored = AccountStore(location: path, vault: vault, integratesWithSystem: false, fetcher: { _, c in self.unused(c) }, activator: { _ in attempts += 1 })
        await restored.refresh(account.id); await restored.refresh(account.id)
        XCTAssertEqual(attempts, 2); XCTAssertEqual(restored.accounts[0].activation?.status, .completed)
        XCTAssertNil(restored.accounts[0].activation?.retryAfter)
    }
    func testAutomaticActivationIsOffByDefaultAndDemoCannotConsume() async throws {
        let credential = Fixture.credential("one"), vault = MemoryVault(); var sends = 0
        let store = AccountStore(location: directory.appendingPathComponent("accounts.json"), vault: vault, integratesWithSystem: false, fetcher: { _, c in self.unused(c) }, activator: { _ in sends += 1 })
        let account = AgentAccount(provider: .codex, snapshot: unused(credential)); try store.connect(account, credential: credential)
        await store.refresh(account.id); XCTAssertEqual(sends, 0); XCTAssertNil(store.accounts[0].activation)
        let demo = AccountStore(location: directory.appendingPathComponent("demo/accounts.json"), integratesWithSystem: false, isDemo: true, activator: { _ in XCTFail("Demo made activation request") })
        demo.resetDemo(); await demo.startAllowance(demo.accounts[0].id); await demo.refreshAll()
    }
    func testAutomaticActivationPersistsAndIsolatesMultipleAccounts() async throws {
        let path = directory.appendingPathComponent("accounts.json"), vault = MemoryVault()
        let a = Fixture.credential("a"), b = Fixture.credential("b"); var sent: [String] = []; var deadlines: [String: Date] = [:]
        let fetch: (AgentAccount, AccountCredential) async throws -> UsageSnapshot = { _, c in
            return self.unused(c, reset: deadlines[c.subject])
        }
        let store = AccountStore(location: path, vault: vault, integratesWithSystem: false, fetcher: fetch, activator: { c in
            let disk = try JSONDecoder().decode([AgentAccount].self, from: Data(contentsOf: path))
            XCTAssertEqual(disk.first { $0.snapshot?.identity == c.registrationIdentity }?.activation?.status, .attempted)
            sent.append(c.subject)
            deadlines[c.subject] = .now.addingTimeInterval(604800)
        })
        for c in [a, b] {
            let account = AgentAccount(provider: .codex, snapshot: unused(c))
            try store.connect(account, credential: c)
            store.setAutomaticActivation(true, for: account.id)
        }
        await store.refreshAll(); XCTAssertEqual(Set(sent), Set([a.subject, b.subject]))
        XCTAssertTrue(store.accounts.allSatisfy { $0.activation?.status == .completed })
        XCTAssertEqual(store.events.filter { $0.kind == .windowStarted }.count, 0)
        // Move the saved observation into the past rather than sleeping a minute.
        var saved = store.accounts
        for index in saved.indices {
            saved[index].activation?.attemptedAt = .now.addingTimeInterval(-120)
            saved[index].activation?.resetObservedAt = .now.addingTimeInterval(-61)
        }
        try JSONEncoder().encode(saved).write(to: path, options: .atomic)
        let restored = AccountStore(location: path, vault: vault, integratesWithSystem: false, fetcher: fetch, activator: { _ in XCTFail("Repeated after relaunch") })
        await restored.refreshAll(); XCTAssertEqual(sent.count, 2)
        XCTAssertTrue(restored.accounts.allSatisfy { $0.activation?.status == .started })
        XCTAssertEqual(restored.events.filter { $0.kind == .windowStarted }.count, 2)
        await restored.refreshAll()
        XCTAssertEqual(restored.events.filter { $0.kind == .windowStarted }.count, 2)
        let debug = String(decoding: try Diagnostics.encode(Diagnostics.bundle(accounts: restored.accounts)), as: UTF8.self)
        XCTAssertFalse(debug.contains(a.accessToken)); XCTAssertFalse(debug.contains(a.subject)); XCTAssertTrue(debug.contains("activationStatus"))
        XCTAssertTrue(debug.contains("activationClockReported")); XCTAssertTrue(debug.contains("activationDeadlineInMinutes"))
        XCTAssertTrue(debug.contains("activationClockObservationAgeMinutes")); XCTAssertTrue(debug.contains("activationCandidate"))
    }
    func testAccountOptInDoesNotActivateAnotherAccountOfTheSameProvider() async throws {
        let path = directory.appendingPathComponent("accounts.json"), vault = MemoryVault()
        let a = Fixture.credential("a"), b = Fixture.credential("b"); var sent: [String] = []
        let store = AccountStore(location: path, vault: vault, integratesWithSystem: false,
            fetcher: { _, c in self.unused(c) }, activator: { sent.append($0.subject) })
        let first = AgentAccount(provider: .codex, snapshot: unused(a)), second = AgentAccount(provider: .codex, snapshot: unused(b))
        try store.connect(first, credential: a); try store.connect(second, credential: b)
        store.setAutomaticActivation(true, for: first.id)
        await store.refreshAll()
        XCTAssertEqual(sent, [a.subject])
        XCTAssertEqual(store.accounts.first { $0.id == second.id }?.automaticActivation, false)
        let restored = AccountStore(location: path, vault: vault, integratesWithSystem: false,
            fetcher: { _, c in self.unused(c) }, activator: { _ in XCTFail("Unselected account or duplicate activation") })
        await restored.refreshAll()
        XCTAssertEqual(restored.accounts.first { $0.id == first.id }?.automaticActivation, true)
        XCTAssertEqual(restored.accounts.first { $0.id == second.id }?.automaticActivation, false)
        // An editor opened before the toggle changed must not overwrite it.
        restored.update(first)
        try restored.connect(first, credential: a)
        XCTAssertEqual(restored.accounts.first { $0.id == first.id }?.automaticActivation, true)
    }
    func testLegacyProviderOptInMigratesOnceAndNewConnectionsDefaultToOff() throws {
        let path = directory.appendingPathComponent("accounts.json"), vault = MemoryVault()
        let a = Fixture.credential("a"), b = Fixture.credential("b"), c = claude()
        let first = AgentAccount(provider: .codex, snapshot: unused(a))
        var optedOut = AgentAccount(provider: .codex, snapshot: unused(b)); optedOut.automaticActivation = false
        let other = AgentAccount(provider: .claude, snapshot: unused(c))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode([first, optedOut, other]).write(to: path)
        let store = AccountStore(location: path, vault: vault, integratesWithSystem: false, legacyActivationProviders: ["codex": true])
        XCTAssertEqual(store.accounts.map(\.automaticActivation), [true, false, false])
        store.setAutomaticActivation(false, for: first.id)
        let restored = AccountStore(location: path, vault: vault, integratesWithSystem: false, legacyActivationProviders: ["codex": true, "claude": true])
        XCTAssertTrue(restored.accounts.allSatisfy { $0.automaticActivation == false })
        let newCredential = Fixture.credential("new"), new = AgentAccount(provider: .codex, snapshot: unused(Fixture.credential("new")))
        try restored.connect(new, credential: newCredential)
        XCTAssertEqual(restored.accounts.last?.automaticActivation, false)
        restored.setAutomaticActivation(true, for: new.id)
        try restored.remove(new.id)
        try restored.connect(new, credential: newCredential)
        XCTAssertEqual(restored.accounts.last?.automaticActivation, false)
    }
    func testFailedRequestIsNotRepeatedAutomaticallyOrPassedOffAsAStart() async throws {
        let credential = Fixture.credential("one"), vault = MemoryVault(); var sends = 0
        let store = AccountStore(location: directory.appendingPathComponent("accounts.json"), vault: vault, integratesWithSystem: false, fetcher: { _, c in self.unused(c) }, activator: { _ in sends += 1; throw URLError(.timedOut) })
        let account = AgentAccount(provider: .codex, snapshot: unused(credential)); try store.connect(account, credential: credential)
        store.setAutomaticActivation(true, for: account.id)
        await store.refresh(account.id); await store.refresh(account.id)
        XCTAssertEqual(sends, 1); XCTAssertEqual(store.accounts[0].activation?.status, .failed)
        XCTAssertFalse(store.events.contains { $0.kind == .windowStarted || $0.kind == .activationSent })
    }
    func testManualActionRefreshesButDoesNotConsumeAnActiveWeek() async throws {
        let credential = Fixture.credential("one"), vault = MemoryVault(); var reads = 0, sends = 0
        let store = AccountStore(location: directory.appendingPathComponent("accounts.json"), vault: vault, integratesWithSystem: false, fetcher: { _, c in reads += 1; return self.unused(c, reset: Date.now.addingTimeInterval(3600)) }, activator: { _ in sends += 1 })
        let account = AgentAccount(provider: .codex, snapshot: unused(credential)); try store.connect(account, credential: credential)
        await store.startAllowance(account.id)
        XCTAssertEqual(reads, 1); XCTAssertEqual(sends, 0); XCTAssertEqual(store.activationMessages[account.id], ActivationError.alreadyActive.localizedDescription)
    }
    func testCompletedRequestSurvivesFailedFollowUpWithoutClaimingClockStart() async throws {
        let credential = Fixture.credential("one"), vault = MemoryVault(); var reads = 0, sends = 0
        let store = AccountStore(location: directory.appendingPathComponent("accounts.json"), vault: vault, integratesWithSystem: false, fetcher: { _, c in reads += 1; if reads > 1 { throw UsageError.unavailable }; return self.unused(c) }, activator: { _ in sends += 1 })
        let account = AgentAccount(provider: .codex, snapshot: unused(credential)); try store.connect(account, credential: credential)
        await store.startAllowance(account.id)
        XCTAssertEqual(sends, 1); XCTAssertEqual(store.accounts[0].activation?.status, .completed)
        XCTAssertTrue(store.activationMessages[account.id]!.contains("could not be updated"))
        XCTAssertFalse(store.events.contains { $0.kind == .windowStarted })
        XCTAssertFalse(store.accounts[0].needsLogin)
    }
    func testPersistenceFailurePreventsConsumption() async throws {
        let credential = Fixture.credential("one"), vault = MemoryVault(); var sends = 0
        let path = directory.appendingPathComponent("accounts.json")
        let store = AccountStore(location: path, vault: vault, integratesWithSystem: false, fetcher: { _, c in self.unused(c) }, activator: { _ in sends += 1 })
        let account = AgentAccount(provider: .codex, snapshot: unused(credential)); try store.connect(account, credential: credential)
        store.setAutomaticActivation(true, for: account.id)
        try FileManager.default.removeItem(at: directory)
        try Data("File blocks metadata directory".utf8).write(to: directory)
        await store.refresh(account.id)
        XCTAssertEqual(sends, 0); XCTAssertNotNil(store.error)
        XCTAssertTrue(store.activationMessages[account.id]!.contains("No request was sent"))
    }
    func testDeletingAccountDuringRequestCannotRestoreItsHistoryOrEvents() async throws {
        let credential = Fixture.credential("one"), vault = MemoryVault()
        let account = AgentAccount(provider: .codex, snapshot: unused(credential))
        var store: AccountStore!
        store = AccountStore(location: directory.appendingPathComponent("accounts.json"), vault: vault, integratesWithSystem: false, fetcher: { _, c in self.unused(c) }, activator: { _ in try store.remove(account.id) })
        try store.connect(account, credential: credential)
        store.setAutomaticActivation(true, for: account.id)
        await store.refresh(account.id)
        XCTAssertTrue(store.accounts.isEmpty); XCTAssertNil(store.histories[account.id]); XCTAssertTrue(store.events.isEmpty)
        XCTAssertNil(try vault.load(id: account.id))
    }
}
