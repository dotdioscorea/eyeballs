import XCTest

final class RequotaUITests: XCTestCase {
    func testActivationProviderSettingsPersistAndClaudePermissionIsExplicit() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "--exit-demo-test", "--reset-activation-settings"]
        app.launch(); app.tabBars.buttons["Settings"].tap()
        app.buttons["activation-settings"].tap()
        let codex = app.switches["Codex"].firstMatch
        XCTAssertTrue(codex.waitForExistence(timeout: 5)); XCTAssertEqual(codex.value as? String, "0")
        XCTAssertEqual(app.switches["Claude"].firstMatch.value as? String, "0")
        codex.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap(); XCTAssertEqual(codex.value as? String, "1")
        let settings = XCTAttachment(screenshot: app.screenshot()); settings.name = "Per-provider activation settings"; settings.lifetime = .keepAlways; add(settings)
        app.terminate(); app.launchArguments.removeAll { $0 == "--reset-activation-settings" }; app.launch()
        app.tabBars.buttons["Settings"].tap(); app.buttons["activation-settings"].tap()
        XCTAssertEqual(app.switches["Codex"].firstMatch.value as? String, "1")
        app.switches["Codex"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.navigationBars.buttons["Settings"].tap(); app.tabBars.buttons["Accounts"].tap()
        app.buttons["layout-tiles"].tap(); app.buttons["account-Work"].tap()
        for _ in 0..<10 { if app.buttons["allow-activation"].isHittable { break }; app.swipeUp() }
        XCTAssertTrue(app.buttons["allow-activation"].isHittable)
        app.buttons["allow-activation"].tap()
        XCTAssertTrue(app.staticTexts["Allow a small request to start an unused weekly window."].waitForExistence(timeout: 5))
        let permission = XCTAttachment(screenshot: app.screenshot()); permission.name = "Optional Claude activation permission"; permission.lifetime = .keepAlways; add(permission)
        app.buttons["Cancel"].tap()
    }
    func testClaudeBankedResetPanelAndKnownZero() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "--claude-reset-fixture", "--exit-demo-test"]
        app.launch()
        XCTAssertTrue(app.buttons["layout-tiles"].waitForExistence(timeout: 10)); app.buttons["layout-tiles"].tap()
        XCTAssertTrue(app.buttons["account-Work"].waitForExistence(timeout: 10))
        app.buttons["account-Work"].tap()
        for _ in 0..<4 { if app.staticTexts["Banked resets"].isHittable { break }; app.swipeUp() }
        XCTAssertTrue(app.staticTexts["1 × Usage reset"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Not usable yet"].exists)
        app.terminate()
        app.launchArguments.append("--claude-spent-reset-fixture")
        app.launch(); app.buttons["account-Work"].tap()
        for _ in 0..<4 { if app.staticTexts["Banked resets"].isHittable { break }; app.swipeUp() }
        XCTAssertTrue(app.staticTexts["None available"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["1 × Usage reset"].exists)
    }
    override func setUp() { continueAfterFailure = false }
    override func tearDown() {
        if (testRun?.failureCount ?? 0) > 0 {
            let failureShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); failureShot.name = "Failure screen"; failureShot.lifetime = .keepAlways; add(failureShot)
            print("FAILURE HOME STATE\n" + XCUIApplication(bundleIdentifier: "com.apple.springboard").debugDescription)
        }
        let app = XCUIApplication(); app.terminate(); app.launchArguments = ["--clear-widget-fixture", "--exit-demo-test"]; app.launch(); app.terminate()
    }
    private func allowSystemSignIn() {
        // Shared sessions ask iOS for permission to use existing browser data.
        // This alert belongs to SpringBoard, rather than the app under test.
        let prompt = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if prompt.waitForExistence(timeout: 5), prompt.buttons["Continue"].exists {
            prompt.buttons["Continue"].tap()
        }
    }
    private func clearFixtureWidgets(_ home: XCUIApplication) {
        for _ in 0..<8 {
            let widgets = home.descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND value == %@", "Requota", "Widget"))
            guard let widget = widgets.allElementsBoundByIndex.first(where: { $0.isHittable }) else { return }
            widget.press(forDuration: 1.2)
            guard home.buttons["Remove Widget"].waitForExistence(timeout: 3) else { XCUIDevice.shared.press(.home); return }
            home.buttons["Remove Widget"].tap()
            let alert = home.alerts.firstMatch
            if alert.waitForExistence(timeout: 3), alert.buttons["Remove"].exists { alert.buttons["Remove"].tap() }
        }
    }
    func testChartGesturesRateLegendAndProviderFilters() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixture", "--native-provider-fixture", "--exit-demo-test"]; app.launch()
        XCTAssertTrue(app.buttons["layout-cards"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Codex"].exists)
        XCTAssertFalse(app.buttons["Gemini"].exists)
        app.tabBars.buttons["Charts"].tap()
        let plot = app.otherElements["history-plot"].firstMatch
        XCTAssertTrue(plot.waitForExistence(timeout: 10))
        let original = plot.value as? String
        let before = XCTAttachment(screenshot: app.screenshot()); before.name = "Shared charts and stable readout"; before.lifetime = .keepAlways; add(before)
        plot.pinch(withScale: 2, velocity: 1)
        XCTAssertNotEqual(plot.value as? String, original)
        XCTAssertTrue(app.buttons["reset-chart-view"].exists)
        let zoomed = plot.value as? String
        let timeline = plot
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 1.08)).press(forDuration: 0.05, thenDragTo: timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 1.08)))
        XCTAssertNotEqual(plot.value as? String, zoomed)
        let zoom = XCTAttachment(screenshot: app.screenshot()); zoom.name = "Pinched and panned chart"; zoom.lifetime = .keepAlways; add(zoom)
        app.buttons["reset-chart-view"].tap()
        XCTAssertEqual(plot.value as? String, original)
        let toggle = app.buttons["chart-smooth"]
        XCTAssertTrue(toggle.exists); if toggle.value as? String != "On" { toggle.tap() }
        let smooth = XCTAttachment(screenshot: app.screenshot()); smooth.name = "Smoothed usage comparison"; smooth.lifetime = .keepAlways; add(smooth)
        app.buttons["Rate"].tap()
        XCTAssertTrue(plot.exists)
        let rate = XCTAttachment(screenshot: app.screenshot()); rate.name = "Averaged rate chart"; rate.lifetime = .keepAlways; add(rate)
    }
    func testContinuousChartReadoutAndAccountSelection() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixture", "--exit-demo-test"]; app.launch()
        app.tabBars.buttons["Charts"].tap()
        let plot = app.otherElements["history-plot"].firstMatch
        XCTAssertTrue(plot.waitForExistence(timeout: 10))
        let original = plot.value as? String
        plot.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.5)).tap()
        let date = app.descendants(matching: .any)["chart-selected-date"].firstMatch
        XCTAssertNotEqual(date.label, "Latest readings")
        let firstDate = date.label
        plot.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.5)).press(forDuration: 0.05, thenDragTo: plot.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        XCTAssertNotEqual(date.label, firstDate)
        XCTAssertEqual(plot.value as? String, original, "Scrubbing inspects without panning")
        XCTAssertTrue(app.buttons["Clear chart selection"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Continuous readout below plot"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["chart-provider-codex"].tap()
        let personal = "00000000-0000-0000-0000-000000000001:week"
        XCTAssertTrue(app.buttons["chart-reading-" + personal].exists)
        XCTAssertFalse(app.buttons["chart-reading-00000000-0000-0000-0000-000000000002:week"].exists)
        app.buttons.matching(NSPredicate(format: "label == %@", "Accounts & metrics")).firstMatch.tap()
        let account = app.buttons["chart-account-00000000-0000-0000-0000-000000000001"]
        XCTAssertTrue(account.waitForExistence(timeout: 5)); XCTAssertEqual(account.value as? String, "On")
        account.tap(); XCTAssertEqual(account.value as? String, "Off")
        let metric = app.buttons["chart-metric-" + personal]
        metric.tap(); XCTAssertEqual(metric.value as? String, "On")
        let filters = XCTAttachment(screenshot: app.screenshot()); filters.name = "Collapsible accounts and metric swatches"; filters.lifetime = .keepAlways; add(filters)
        app.buttons.matching(NSPredicate(format: "label == %@", "Accounts & metrics")).firstMatch.tap()
        app.buttons["chart-provider-all"].tap()
        XCTAssertTrue(app.buttons["chart-reading-" + personal].exists)
        XCTAssertTrue(app.buttons["chart-reading-00000000-0000-0000-0000-000000000002:week"].exists, "Provider filtering preserves selection")
    }
    func testCombinedActivityAndDayBreakdown() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixture", "--exit-demo-test"]; app.launch()
        app.tabBars.buttons["Charts"].tap(); app.buttons["Activity"].tap()
        XCTAssertTrue(app.otherElements["combined-activity"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Monthly"].firstMatch.tap()
        let cell = app.buttons["heatmap-cell-monthly-2"]
        XCTAssertTrue(cell.waitForExistence(timeout: 5)); XCTAssertEqual(app.buttons.matching(identifier: "heatmap-cell-monthly-2").count, 1)
        let map = XCTAttachment(screenshot: app.screenshot()); map.name = "Combined monthly Activity"; map.lifetime = .keepAlways; add(map)
        cell.tap()
        XCTAssertTrue(app.staticTexts["DAY CONSUMPTION"].waitForExistence(timeout: 5)); XCTAssertTrue(app.staticTexts["Coverage"].exists)
        XCTAssertTrue(app.staticTexts["Personal"].exists); XCTAssertTrue(app.staticTexts["Work"].exists)
        let breakdown = XCTAttachment(screenshot: app.screenshot()); breakdown.name = "Combined Activity day breakdown"; breakdown.lifetime = .keepAlways; add(breakdown)
        app.buttons["Done"].tap()
        app.buttons["chart-provider-codex"].tap()
        XCTAssertTrue(app.staticTexts["Average quota used"].exists)
    }
    func testAdditionalProviderStatistics() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixture", "--provider-stats-fixture", "--exit-demo-test"]; app.launch()
        app.buttons["compact-mode"].tap()
        app.buttons["sort-accounts"].tap(); app.buttons["Custom order"].tap()
        app.buttons["account-Research"].tap()
        for _ in 0..<3 { if app.staticTexts["Amount spent"].isHittable { break }; app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Amount spent"].exists); XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "12.34")).firstMatch.exists)
        let grok = XCTAttachment(screenshot: app.screenshot()); grok.name = "Grok reported on-demand spend"; grok.lifetime = .keepAlways; add(grok)
        app.navigationBars.buttons["Requota"].tap(); app.buttons["account-Travel"].tap()
        for _ in 0..<4 { if app.staticTexts["Additional usage"].isHittable { break }; app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Additional usage"].exists); XCTAssertTrue(app.staticTexts["Unlimited"].exists)
        let copilot = XCTAttachment(screenshot: app.screenshot()); copilot.name = "Copilot additional budget and unlimited counters"; copilot.lifetime = .keepAlways; add(copilot)
        app.navigationBars.buttons["Requota"].tap(); app.buttons["account-Studio"].tap()
        for _ in 0..<6 { if app.buttons["configure-display"].isHittable { break }; app.swipeDown() }
        XCTAssertTrue(app.staticTexts["123 left"].exists)
        let gemini = XCTAttachment(screenshot: app.screenshot()); gemini.name = "Gemini actual remaining request count"; gemini.lifetime = .keepAlways; add(gemini)
    }
    func testLockScreenAccessoryLayouts() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixture", "--exit-demo-test", "--accessory-preview"]; app.launch()
        XCTAssertTrue(app.staticTexts["Accessory previews"].waitForExistence(timeout: 10))
        // Accessory content exposes a combined account/metric label to VoiceOver.
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "100%")).firstMatch.exists); XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "0%")).firstMatch.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Accessory content at circular rectangular and inline sizes"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    func testLowAndResetRemindersDeliverWhileAppClosed() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixture", "--exit-demo-test"]; app.launch()
        app.tabBars.buttons["Settings"].tap(); app.buttons["notification-settings"].tap()
        let enabled = app.switches["notifications-enabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 5))
        if enabled.value as? String == "1" { enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        app.terminate(); app.launchArguments += ["--notification-fixture", "--reset-notification-fixture"]; app.launch()
        app.tabBars.buttons["Settings"].tap(); app.buttons["notification-settings"].tap()
        XCTAssertTrue(enabled.waitForExistence(timeout: 5)); enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let home = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if home.alerts.firstMatch.waitForExistence(timeout: 2), home.alerts.firstMatch.buttons["Allow"].exists { home.alerts.firstMatch.buttons["Allow"].tap() }
        XCTAssertEqual(enabled.value as? String, "1")
        XCUIDevice.shared.press(.home)
        // Start beside the Dynamic Island; dragging over it does not open Notification Centre.
        home.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.01)).press(forDuration: 0.1, thenDragTo: home.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.8)))
        print("NOTIFICATION CENTER\n" + home.debugDescription)
        let warning = home.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "weekly reset approaching")).firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 10))
        let group = home.scrollViews.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "ListCell", "Grouped")).firstMatch
        if group.exists { group.tap() }
        let low = home.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Weekly low")).firstMatch
        XCTAssertTrue(low.waitForExistence(timeout: 5))
        let warnings = XCTAttachment(screenshot: home.screenshot()); warnings.name = "Delivered low allowance and approaching reset warnings"; warnings.lifetime = .keepAlways; add(warnings)
        let reset = home.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "weekly reset due")).firstMatch
        XCTAssertTrue(reset.waitForExistence(timeout: 50))
        let due = XCTAttachment(screenshot: home.screenshot()); due.name = "Scheduled weekly reset with app closed"; due.lifetime = .keepAlways; add(due)
        XCUIDevice.shared.press(.home)
    }
    func testNotificationControlsAndProviderPersistence() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixture", "--exit-demo-test"]; app.launch()
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 10)); app.tabBars.buttons["Settings"].tap()
        app.buttons["notification-settings"].tap()
        XCTAssertTrue(app.switches["notifications-enabled"].waitForExistence(timeout: 5))
        let enabled = app.switches["notifications-enabled"]
        if enabled.value as? String != "1" {
            enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            let home = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            if home.alerts.firstMatch.waitForExistence(timeout: 4), home.alerts.firstMatch.buttons["Allow"].exists { home.alerts.firstMatch.buttons["Allow"].tap() }
        }
        XCTAssertEqual(enabled.value as? String, "1")
        let initial = XCTAttachment(screenshot: app.screenshot()); initial.name = "Notification permission and low allowance controls"; initial.lifetime = .keepAlways; add(initial)
        for _ in 0..<5 { if app.buttons["Claude, Default"].isHittable || app.buttons["Claude"].isHittable { break }; app.swipeUp() }
        let claude = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Claude")).firstMatch
        XCTAssertTrue(claude.exists); claude.tap()
        XCTAssertTrue(app.switches["Use default settings"].waitForExistence(timeout: 5))
        if app.switches["Use default settings"].value as? String == "1" { app.switches["Use default settings"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        XCTAssertTrue(app.switches["Notify for this provider"].exists)
        app.switches["Notify for this provider"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let custom = XCTAttachment(screenshot: app.screenshot()); custom.name = "Claude notification override"; custom.lifetime = .keepAlways; add(custom)
        app.terminate(); app.launch()
        app.tabBars.buttons["Settings"].tap(); app.buttons["notification-settings"].tap()
        for _ in 0..<6 { if app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Claude")).firstMatch.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(app.buttons["Claude, Off"].exists)
        // Restore the fixture's defaults for later tests.
        app.buttons["Claude, Off"].tap(); app.switches["Use default settings"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    }
    func testReleaseDemoAndRestoration() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixture", "--exit-demo-test"]; app.launch()
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 10)); app.tabBars.buttons["Settings"].tap()
        app.buttons["start-demo"].tap()
        XCTAssertTrue(app.buttons["exit-demo"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Settings"].tap(); app.buttons["Reset sample data"].tap()
        app.tabBars.buttons["Accounts"].tap()
        app.buttons["sort-accounts"].tap(); app.buttons["Custom order"].tap()
        XCTAssertTrue(app.buttons["account-Personal"].waitForExistence(timeout: 5))
        app.buttons["layout-cards"].tap()
        let cards = XCTAttachment(screenshot: app.screenshot()); cards.name = "Release demo cards"; cards.lifetime = .keepAlways; add(cards)
        app.buttons["compact-mode"].tap()
        let compact = XCTAttachment(screenshot: app.screenshot()); compact.name = "Release demo compact"; compact.lifetime = .keepAlways; add(compact)
        app.buttons["layout-tiles"].tap()
        let dashboard = XCTAttachment(screenshot: app.screenshot()); dashboard.name = "Release demo tiles"; dashboard.lifetime = .keepAlways; add(dashboard)
        app.buttons["account-Personal"].tap()
        XCTAssertTrue(app.staticTexts["Banked resets"].waitForExistence(timeout: 5))
        for _ in 0..<4 { if app.staticTexts["Usage history"].exists { break }; app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Usage history"].waitForExistence(timeout: 5))
        let history = XCTAttachment(screenshot: app.screenshot()); history.name = "Release demo history"; history.lifetime = .keepAlways; add(history)
        app.navigationBars.buttons["Requota"].tap()
        XCTAssertTrue(app.tabBars.buttons["Events"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Events"].tap()
        XCTAssertTrue(app.staticTexts["Banked reset detected"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Settings"].tap()
        app.buttons["Simulate early reset"].tap()
        app.tabBars.buttons["Events"].tap()
        XCTAssertTrue(app.staticTexts["Banked reset used"].waitForExistence(timeout: 5))
        app.terminate(); app.launchArguments = ["--ui-fixture"]; app.launch()
        XCTAssertTrue(app.buttons["exit-demo"].waitForExistence(timeout: 10))
        app.buttons["exit-demo"].tap()
        XCTAssertTrue(app.buttons["account-Personal"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["exit-demo"].exists)
        app.tabBars.buttons["Settings"].tap(); app.buttons["Privacy & storage"].tap()
        XCTAssertTrue(app.buttons["Privacy policy"].waitForExistence(timeout: 5))
    }
    func testAllProviderConnectionsAndCancellation() {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.buttons["connect-first"].waitForExistence(timeout: 10))
        app.buttons["connect-first"].tap()
        app.buttons["connect-codex"].tap()
        XCTAssertTrue(app.buttons["Continue with ChatGPT"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["choose-another-login"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["connect-claude"].waitForExistence(timeout: 5))
        app.buttons["connect-claude"].tap()
        XCTAssertTrue(app.buttons["Continue with Claude"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["choose-another-login"].exists)
        app.buttons["Cancel"].tap()
        app.buttons["connect-grok"].tap()
        XCTAssertTrue(app.buttons["Continue with Grok"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["choose-another-login"].exists)
        app.buttons["Cancel"].tap(); app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["connect-first"].exists)
    }
    func testPerplexityEmailFormAndCancellation() {
        let app = XCUIApplication(); app.launchArguments = ["--exit-demo-test"]; app.launch()
        XCTAssertTrue(app.buttons["connect-first"].waitForExistence(timeout: 10)); app.buttons["connect-first"].tap()
        for _ in 0..<3 { if app.buttons["connect-perplexity"].isHittable { break }; app.swipeUp() }
        XCTAssertTrue(app.buttons["connect-perplexity"].waitForExistence(timeout: 5)); app.buttons["connect-perplexity"].tap()
        let email = app.textFields["perplexity-email"]
        XCTAssertTrue(email.waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["send-perplexity-code"].isEnabled)
        email.tap(); email.typeText("person@example.test")
        XCTAssertTrue(app.buttons["send-perplexity-code"].isEnabled)
        XCTAssertFalse(app.buttons["Save connection"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Perplexity native email form"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Cancel"].tap(); app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["connect-first"].waitForExistence(timeout: 5))
    }
    func testDevinPresentsSystemSignInAndCancelsWithoutSaving() {
        let app = XCUIApplication(); app.launchArguments = ["--exit-demo-test"]; app.launch()
        XCTAssertTrue(app.buttons["connect-first"].waitForExistence(timeout: 10)); app.buttons["connect-first"].tap()
        for _ in 0..<4 { if app.buttons["connect-devin"].isHittable { break }; app.swipeUp() }
        app.buttons["connect-devin"].tap(); app.buttons["Continue with Devin"].tap(); allowSystemSignIn()
        let service = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        XCTAssertTrue(service.buttons["Cancel"].waitForExistence(timeout: 20))
        XCTAssertTrue(service.webViews.firstMatch.waitForExistence(timeout: 20))
        let url = service.buttons["URL"].value as? String ?? ""
        XCTAssertTrue(url.contains("devin.ai"), url)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Devin native system sign-in"; shot.lifetime = .keepAlways; add(shot)
        service.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Sign-in was cancelled. Your saved accounts are unchanged."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Save connection"].exists)
    }
    func testDevinDailyAndWeeklyAcrossLayouts() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixture", "--exit-demo-test"]; app.launch()
        app.tabBars.buttons["Settings"].tap(); app.buttons["start-demo"].tap()
        app.tabBars.buttons["Settings"].tap(); app.buttons["Reset sample data"].tap(); app.tabBars.buttons["Accounts"].tap()
        app.textFields["search-accounts"].tap(); app.textFields["search-accounts"].typeText("Devin\n")
        XCTAssertTrue(app.buttons["account-Devin"].waitForExistence(timeout: 5))
        for layout in ["layout-cards", "compact-mode", "layout-tiles"] {
            app.buttons[layout].tap()
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Devin daily and weekly " + layout; shot.lifetime = .keepAlways; add(shot)
        }
        app.buttons["account-Devin"].tap()
        XCTAssertTrue(app.staticTexts["Daily"].exists); XCTAssertTrue(app.staticTexts["Weekly"].exists)
        XCTAssertTrue(app.staticTexts["Weekly time"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)
    }
    func testAmpPresentsSystemSignInAndCancelsWithoutSaving() {
        let app = XCUIApplication(); app.launchArguments = ["--exit-demo-test"]; app.launch()
        app.buttons["connect-first"].tap()
        for _ in 0..<4 { if app.buttons["connect-amp"].isHittable { break }; app.swipeUp() }
        app.buttons["connect-amp"].tap(); app.buttons["Continue with Amp"].tap(); allowSystemSignIn()
        let service = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        XCTAssertTrue(service.buttons["Cancel"].waitForExistence(timeout: 20))
        XCTAssertTrue(service.webViews.firstMatch.waitForExistence(timeout: 20))
        let url = service.buttons["URL"].value as? String ?? ""
        XCTAssertTrue(url.contains("ampcode.com"), url)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Amp native system sign-in"; shot.lifetime = .keepAlways; add(shot)
        service.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Sign-in was cancelled. Your saved accounts are unchanged."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Save connection"].exists)
    }
    func testPerplexityCountsAndHistoryAcrossLayouts() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixture", "--exit-demo-test"]; app.launch()
        app.tabBars.buttons["Settings"].tap(); app.buttons["start-demo"].tap()
        app.tabBars.buttons["Settings"].tap(); app.buttons["Reset sample data"].tap(); app.tabBars.buttons["Accounts"].tap()
        let search = app.textFields["search-accounts"]; search.tap(); search.typeText("Perplexity\n")
        XCTAssertTrue(app.buttons["account-Search"].waitForExistence(timeout: 5))
        for layout in ["layout-cards", "compact-mode", "layout-tiles"] {
            app.buttons[layout].tap()
            XCTAssertFalse(app.staticTexts["—%"].exists)
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Perplexity counts \(layout)"; shot.lifetime = .keepAlways; add(shot)
        }
        app.buttons["account-Search"].tap()
        XCTAssertTrue(app.staticTexts["240 left"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Next reset"].exists)
        for _ in 0..<3 { if app.descendants(matching: .any)["history-plot"].firstMatch.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(app.descendants(matching: .any)["history-plot"].firstMatch.waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Perplexity remaining search history"; shot.lifetime = .keepAlways; add(shot)
    }
    func testAmpBalanceAcrossLayoutsAndDetail() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixture", "--exit-demo-test"]; app.launch()
        app.tabBars.buttons["Settings"].tap(); app.buttons["start-demo"].tap()
        app.tabBars.buttons["Settings"].tap(); app.buttons["Reset sample data"].tap(); app.tabBars.buttons["Accounts"].tap()
        app.textFields["search-accounts"].tap(); app.textFields["search-accounts"].typeText("Amp\n")
        XCTAssertTrue(app.buttons["account-Amp"].waitForExistence(timeout: 5))
        for layout in ["layout-cards", "compact-mode", "layout-tiles"] {
            app.buttons[layout].tap()
            let account = app.buttons["account-Amp"]
            XCTAssertTrue(account.label.contains("$5.00"), account.debugDescription)
            XCTAssertFalse(account.label.contains("No quota reported"))
            XCTAssertFalse(account.label.contains("—%"))
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Amp credit balance " + layout; shot.lifetime = .keepAlways; add(shot)
        }
        app.buttons["account-Amp"].tap()
        XCTAssertTrue(app.staticTexts["US$5.00"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Personal credits"].exists)
        XCTAssertFalse(app.staticTexts["No usage limit reported."].exists)
        XCTAssertFalse(app.staticTexts["Choose a metric."].exists)
        XCTAssertFalse(app.staticTexts["Usage history"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Amp personal credit details"; shot.lifetime = .keepAlways; add(shot)
    }
    func testHistorySelectionEventsAndCalendar() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixture", "--exit-demo-test"]; app.launch()
        app.tabBars.buttons["Settings"].tap(); app.buttons["start-demo"].tap()
        app.tabBars.buttons["Settings"].tap(); app.buttons["Reset sample data"].tap()
        app.tabBars.buttons["Accounts"].tap(); app.buttons["account-Personal"].tap()
        app.swipeUp()
        let plot = app.descendants(matching: .any)["history-plot"].firstMatch
        XCTAssertTrue(plot.waitForExistence(timeout: 10))
        let start = plot.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.55))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: start.screenPoint.y / app.frame.height))
        start.press(forDuration: 0.8, thenDragTo: end)
        let selection = XCTAttachment(screenshot: app.screenshot()); selection.name = "History selection beyond right edge"; selection.lifetime = .keepAlways; add(selection)
        XCTAssertTrue(app.buttons["chart-event-weeklyReset"].firstMatch.exists)
        app.buttons["chart-event-weeklyReset"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Events"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Weekly reset"].exists)
        app.buttons["Done"].tap()
        app.buttons["90d"].firstMatch.tap()
        plot.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).press(forDuration: 0.8, thenDragTo: end)
        let longSelection = XCTAttachment(screenshot: app.screenshot()); longSelection.name = "90 day history selection"; longSelection.lifetime = .keepAlways; add(longSelection)
        app.swipeUp()
        XCTAssertTrue(app.buttons["Daily"].firstMatch.waitForExistence(timeout: 5)); app.buttons["Daily"].firstMatch.tap()
        let daily = XCTAttachment(screenshot: app.screenshot()); daily.name = "Activity day and burn rate"; daily.lifetime = .keepAlways; add(daily)
        app.buttons["Monthly"].firstMatch.tap()
        XCTAssertTrue(app.buttons["heatmap-cell-monthly-0"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["heatmap-cell-monthly-1"].exists)
        let monthly = XCTAttachment(screenshot: app.screenshot()); monthly.name = "Activity calendar month"; monthly.lifetime = .keepAlways; add(monthly)
    }
    func testFourRingsFitFullPercentageAndCreditBalance() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixture", "--ring-boundaries", "--exit-demo-test"]; app.launch()
        if app.buttons["Clear search"].exists { app.buttons["Clear search"].tap() }
        app.buttons["layout-cards"].tap()
        let cards = XCTAttachment(screenshot: app.screenshot()); cards.name = "Four rings 100 percent cards"; cards.lifetime = .keepAlways; add(cards)
        app.buttons["layout-tiles"].tap()
        let tiles = XCTAttachment(screenshot: app.screenshot()); tiles.name = "Four rings 100 percent tiles"; tiles.lifetime = .keepAlways; add(tiles)
        app.buttons["account-Personal"].tap()
        XCTAssertTrue(app.staticTexts["Weekly time"].exists); XCTAssertTrue(app.staticTexts["5-hour window time"].exists)
        Thread.sleep(forTimeInterval: 0.5) // Capture after the navigation transition.
        let detail = XCTAttachment(screenshot: app.screenshot()); detail.name = "Four rings 100 percent detail"; detail.lifetime = .keepAlways; add(detail)
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["account-Mac mini"].tap()
        XCTAssertTrue(app.staticTexts["Credits"].exists); XCTAssertTrue(app.staticTexts["15"].exists)
        XCTAssertTrue(app.staticTexts["Weekly allowance exhausted"].exists)
    }
    func testCreditTilesAndUpdateSettings() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixture", "--ring-boundaries", "--credit-tile-fixture", "--exit-demo-test"]; app.launch()
        XCTAssertTrue(app.buttons["layout-tiles"].waitForExistence(timeout: 10))
        if app.buttons["Clear search"].exists { app.buttons["Clear search"].tap() }
        app.buttons["sort-accounts"].tap(); app.buttons["Custom order"].tap(); app.buttons["layout-tiles"].tap()
        XCTAssertTrue(app.staticTexts["1,234.57"].exists); XCTAssertTrue(app.staticTexts["0.5"].exists)
        XCTAssertFalse(app.staticTexts["1234.567891234"].exists)
        let tiles = XCTAttachment(screenshot: app.screenshot()); tiles.name = "Credit tiles four rings and balance-only"; tiles.lifetime = .keepAlways; add(tiles)
        app.tabBars.buttons["Settings"].tap(); app.buttons["Updates"].tap()
        XCTAssertTrue(app.staticTexts["Background App Refresh"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)
        let settings = XCTAttachment(screenshot: app.screenshot()); settings.name = "Update settings"; settings.lifetime = .keepAlways; add(settings)
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(app.staticTexts["Background App Refresh"].waitForExistence(timeout: 5))
    }
    func testCompactDisplayConfigurationAndCopyCleanup() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixture"]; app.launch()
        XCTAssertTrue(app.buttons["compact-mode"].waitForExistence(timeout: 10))
        if app.buttons["compact-mode"].value as? String != "On" { app.buttons["compact-mode"].tap() }
        XCTAssertTrue(app.buttons["sort-accounts"].exists)
        app.buttons["sort-accounts"].tap()
        app.buttons["Name"].tap()
        if !app.textFields["search-accounts"].exists { app.buttons["Search accounts"].tap() }
        app.textFields["search-accounts"].tap(); app.textFields["search-accounts"].typeText("Personal")
        app.buttons["account-Personal"].tap()
        XCTAssertFalse(app.buttons["Refresh usage"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)
        app.buttons["configure-display"].tap()
        app.swipeUp()
        XCTAssertTrue(app.buttons["metric-week:time"].waitForExistence(timeout: 5))
        let timeMetric = app.buttons["metric-week:time"]
        XCTAssertEqual(timeMetric.value as? String, "On") // Weekly time is enabled without configuration.
        timeMetric.tap(); XCTAssertEqual(timeMetric.value as? String, "Off")
        timeMetric.tap()
        XCTAssertEqual(timeMetric.value as? String, "On")
        let sessionTime = app.buttons["metric-session:time"]
        XCTAssertTrue(sessionTime.waitForExistence(timeout: 5))
        if sessionTime.value as? String == "Off" { sessionTime.tap() }
        XCTAssertEqual(sessionTime.value as? String, "On")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Weekly time"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Settings"].tap()
        XCTAssertFalse(app.buttons["Add a widget"].exists)
        XCTAssertFalse(app.buttons["Preview with sample accounts"].exists)
        XCTAssertTrue(app.buttons["Source code"].exists)
        app.buttons["Report a problem"].tap()
        let debugToggle = app.switches["include-debug-bundle"]
        debugToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(debugToggle.value as? String, "1")
        XCTAssertTrue(app.buttons["Save or share debug bundle"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["compact-mode"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["compact-mode"].value as? String, "On")
    }
    func testTilesDragOrderChartsAndEvents() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixture"]; app.launch()
        XCTAssertTrue(app.buttons["layout-tiles"].waitForExistence(timeout: 10)); app.buttons["layout-tiles"].tap()
        app.buttons["sort-accounts"].tap(); app.buttons["Custom order"].tap()
        if app.buttons["Clear search"].exists { app.buttons["Clear search"].tap() }
        let personal = app.buttons["account-Personal"], work = app.buttons["account-Work"]
        XCTAssertTrue(personal.waitForExistence(timeout: 5)); XCTAssertTrue(work.exists)
        XCTAssertLessThan(abs(personal.frame.width - personal.frame.height), 3)
        let workStartedLeft = work.frame.minX < personal.frame.minX
        personal.press(forDuration: 1.0, thenDragTo: work)
        XCTAssertEqual(work.frame.minX < personal.frame.minX, !workStartedLeft)
        let tiles = XCTAttachment(screenshot: app.screenshot()); tiles.name = "Square tiles and custom order"; tiles.lifetime = .keepAlways; add(tiles)
        app.terminate(); app.launch()
        XCTAssertEqual(app.buttons["layout-tiles"].value as? String, "On")
        XCTAssertEqual(app.buttons["account-Work"].frame.minX < app.buttons["account-Personal"].frame.minX, !workStartedLeft)
        app.tabBars.buttons["Charts"].tap()
        XCTAssertTrue(app.buttons["chart-accounts"].waitForExistence(timeout: 5))
        let lines = XCTAttachment(screenshot: app.screenshot()); lines.name = "Account comparison lines"; lines.lifetime = .keepAlways; add(lines)
        app.buttons["Activity"].tap()
        XCTAssertTrue(app.buttons["Daily"].firstMatch.waitForExistence(timeout: 5)); app.buttons["Daily"].firstMatch.tap()
        let heatmap = XCTAttachment(screenshot: app.screenshot()); heatmap.name = "Daily usage heatmap"; heatmap.lifetime = .keepAlways; add(heatmap)
        app.tabBars.buttons["Events"].tap(); XCTAssertTrue(app.staticTexts["No events recorded."].waitForExistence(timeout: 5))
    }
    func testSystemAuthenticationPresentation() {
        let app = XCUIApplication(); app.launch()
        app.buttons["connect-first"].tap(); app.buttons["connect-codex"].tap()
        let service = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        for button in ["Continue with ChatGPT", "choose-another-login"] {
            app.buttons[button].tap()
            allowSystemSignIn()
            XCTAssertTrue(service.buttons["Cancel"].waitForExistence(timeout: 30))
            XCTAssertTrue(service.textFields["Email address"].waitForExistence(timeout: 45))
            XCTAssertTrue((service.buttons["URL"].value as? String)?.contains("auth.openai.com") == true)
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "System authentication \(button) — no credentials entered"
            screenshot.lifetime = .keepAlways; add(screenshot)
            service.buttons["Cancel"].tap()
            XCTAssertTrue(app.staticTexts["Sign-in was cancelled. Your saved accounts are unchanged."].waitForExistence(timeout: 5))
        }
        app.buttons["Cancel"].tap(); app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["connect-first"].waitForExistence(timeout: 5))
        // This verifies presentation and cancellation; real authorization is a separate release check.
    }
    func testClaudeAndGrokPresentProviderLoginPages() {
        let app = XCUIApplication(); app.launch()
        app.buttons["connect-first"].tap()
        for provider in ["Claude", "Grok"] {
            app.buttons["connect-" + provider.lowercased()].tap()
            app.buttons["Continue with " + provider].tap()
            allowSystemSignIn()
            let service = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
            XCTAssertTrue(service.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", "Close", "Cancel")).firstMatch.waitForExistence(timeout: 15))
            XCTAssertTrue(service.webViews.firstMatch.waitForExistence(timeout: 15))
            let address = service.buttons["URL"].value as? String ?? ""
            XCTAssertTrue(provider == "Claude" ? address.contains("claude.") : address.contains("x.ai"), address)
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = provider + " provider login — no credentials entered"
            screenshot.lifetime = .keepAlways; add(screenshot)
            service.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", "Close", "Cancel")).firstMatch.tap()
            XCTAssertTrue(app.staticTexts["Sign-in was cancelled. Your saved accounts are unchanged."].waitForExistence(timeout: 5))
            app.buttons["Cancel"].tap()
        }
    }
    func testGeminiPresentsGoogleSystemSignInAndCancelsWithoutSaving() {
        let app = XCUIApplication(); app.launch()
        app.buttons["connect-first"].tap()
        app.buttons["connect-gemini"].tap()
        app.buttons["Continue with Gemini"].tap(); allowSystemSignIn()
        let service = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        let cancel = service.buttons["Cancel"]
        print("GOOGLE AUTHENTICATION STATE\n" + service.debugDescription)
        XCTAssertTrue(cancel.waitForExistence(timeout: 15))
        XCTAssertTrue(service.webViews.firstMatch.waitForExistence(timeout: 15))
        let url = service.buttons["URL"].value as? String ?? ""
        XCTAssertTrue(url.contains("accounts.google.com"), url)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Google system sign-in — no account created"; shot.lifetime = .keepAlways; add(shot)
        cancel.tap()
        XCTAssertTrue(app.staticTexts["Sign-in was cancelled. Your saved accounts are unchanged."].waitForExistence(timeout: 5))
    }
    func testClinePresentsSystemSignInAndCancelsWithoutSaving() {
        let app = XCUIApplication(); app.launch()
        app.buttons["connect-first"].tap()
        if !app.buttons["connect-cline"].isHittable { app.swipeUp() }
        app.buttons["connect-cline"].tap()
        app.buttons["Continue with Cline"].tap(); allowSystemSignIn()
        let service = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        XCTAssertTrue(service.buttons["Cancel"].waitForExistence(timeout: 15))
        XCTAssertTrue(service.webViews.firstMatch.waitForExistence(timeout: 15))
        let url = service.buttons["URL"].value as? String ?? ""
        XCTAssertTrue(url.contains("authkit.cline.bot"), url)
        XCTAssertTrue(service.staticTexts["Welcome to Cline"].firstMatch.waitForExistence(timeout: 30))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Cline system sign-in"; shot.lifetime = .keepAlways; add(shot)
        service.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Sign-in was cancelled. Your saved accounts are unchanged."].waitForExistence(timeout: 5))
    }
    func testKimiPresentsRegionalSystemSignInAndCancelsWithoutSaving() {
        let app = XCUIApplication(); app.launch()
        app.buttons["connect-first"].tap()
        app.swipeUp(); app.buttons["connect-kimi"].tap()
        XCTAssertTrue(app.buttons["International"].exists)
        app.buttons["Continue with Kimi Code"].tap(); allowSystemSignIn()
        let service = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        XCTAssertTrue(service.buttons["Cancel"].waitForExistence(timeout: 20))
        XCTAssertTrue(service.webViews.firstMatch.waitForExistence(timeout: 20))
        let url = service.buttons["URL"].value as? String ?? ""
        XCTAssertTrue(url.contains("kimi.ai"), url)
        XCTAssertTrue(service.buttons["Continue with Google"].waitForExistence(timeout: 30))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Kimi international system sign-in"; shot.lifetime = .keepAlways; add(shot)
        service.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Sign-in was cancelled. Your saved accounts are unchanged."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Save connection"].exists)
    }
    func testProviderStatisticsPanels() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixture", "--exit-demo-test"]; app.launch()
        app.tabBars.buttons["Settings"].tap(); app.buttons["start-demo"].tap()
        app.tabBars.buttons["Settings"].tap(); app.buttons["Reset sample data"].tap()
        app.tabBars.buttons["Accounts"].tap(); app.buttons["layout-cards"].tap()
        app.buttons["sort-accounts"].tap(); app.buttons["Custom order"].tap()
        if !app.buttons["account-Work"].exists { app.swipeUp() }
        app.buttons["account-Work"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)))
        XCTAssertTrue(app.staticTexts["Usage credits"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Share of weekly usage"].exists)
        XCTAssertTrue(app.staticTexts["Claude Code"].exists)
        let claude = XCTAttachment(screenshot: app.screenshot()); claude.name = "Claude spending and app breakdown"; claude.lifetime = .keepAlways; add(claude)
        app.navigationBars.buttons["Requota"].tap()
        app.buttons["account-Personal"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)))
        XCTAssertTrue(app.staticTexts["Estimated local messages"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Model access"].exists)
        let codex = XCTAttachment(screenshot: app.screenshot()); codex.name = "Codex credits and model access"; codex.lifetime = .keepAlways; add(codex)
    }
    func testCursorPresentsSystemSignInAndCancelsWithoutSaving() {
        let app = XCUIApplication(); app.launch()
        app.buttons["connect-first"].tap(); app.buttons["connect-cursor"].tap()
        app.buttons["Continue with Cursor"].tap(); allowSystemSignIn()
        let service = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        XCTAssertTrue(service.buttons["Cancel"].waitForExistence(timeout: 15))
        XCTAssertTrue(service.webViews.firstMatch.waitForExistence(timeout: 15))
        let url = service.buttons["URL"].value as? String ?? ""
        XCTAssertTrue(url.contains("cursor.com") || url.contains("cursor.sh"), url)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Cursor system sign-in"; shot.lifetime = .keepAlways; add(shot)
        service.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Sign-in was cancelled. Your saved accounts are unchanged."].waitForExistence(timeout: 5))
    }
    func testCopilotPresentsGitHubSystemVerificationAndCancelsWithoutSaving() {
        let app = XCUIApplication(); app.launch()
        app.buttons["connect-first"].tap(); app.buttons["connect-copilot"].tap()
        app.buttons["Continue with Copilot"].tap()
        XCTAssertTrue(app.staticTexts["github-verification-code"].waitForExistence(timeout: 25))
        app.buttons["open-github-verification"].tap(); allowSystemSignIn()
        let service = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        XCTAssertTrue(service.buttons["Cancel"].waitForExistence(timeout: 15))
        XCTAssertTrue((service.buttons["URL"].value as? String)?.contains("github.com") == true)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "GitHub device sign-in — no grant accepted"; shot.lifetime = .keepAlways; add(shot)
        service.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Sign-in was cancelled. Your saved accounts are unchanged."].waitForExistence(timeout: 5))
    }
    func testWidgetAccountPickerStaysOpenAndSelectsAccount() {
        let app = XCUIApplication(); app.launchArguments = ["--widget-fixture", "--ring-boundaries"]; app.launch()
        XCTAssertTrue(app.buttons["compact-mode"].waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)
        let home = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        clearFixtureWidgets(home)
        let visibleIcon = NSPredicate { _, _ in home.icons.matching(identifier: "Safari").allElementsBoundByIndex.contains { $0.isHittable } }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: visibleIcon, object: nil)], timeout: 10), .completed)
        let icon = home.icons.matching(identifier: "Safari").allElementsBoundByIndex.first { $0.isHittable }!
        icon.press(forDuration: 1.2)
        XCTAssertTrue(home.buttons["Edit Home Screen"].waitForExistence(timeout: 5))
        home.buttons["Edit Home Screen"].tap()
        home.buttons["Edit"].tap(); home.buttons["Add Widget"].tap()
        let search = home.searchFields["Search Widgets"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("Requota")
        let result = home.buttons["Requota"].firstMatch
        if result.waitForExistence(timeout: 3) { result.tap() }
        else { home.staticTexts["Requota"].firstMatch.tap() }
        let addWidget = home.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Add Widget")).firstMatch
        XCTAssertTrue(addWidget.waitForExistence(timeout: 5))
        addWidget.tap()
        if home.buttons["Done"].waitForExistence(timeout: 5) { home.buttons["Done"].tap() }
        let widget = home.descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND value == %@", "Requota", "Widget")).firstMatch
        XCTAssertTrue(widget.waitForExistence(timeout: 5))
        print("WIDGET TARGET " + widget.debugDescription)
        widget.press(forDuration: 1.2)
        XCTAssertTrue(home.buttons["Edit Widget"].waitForExistence(timeout: 5))
        home.buttons["Edit Widget"].tap()
        let parameter = home.cells.containing(.staticText, identifier: "Account").firstMatch
        XCTAssertTrue(parameter.waitForExistence(timeout: 20))
        parameter.buttons.firstMatch.tap()
        XCTAssertTrue(home.staticTexts["Personal"].waitForExistence(timeout: 5))
        home.staticTexts["Personal"].firstMatch.tap()
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Widget configured with Personal"; shot.lifetime = .keepAlways; add(shot)
        XCUIDevice.shared.press(.home); app.terminate()
        XCTAssertTrue(home.staticTexts["Personal"].firstMatch.waitForExistence(timeout: 15))
        let face = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); face.name = "Small widget four rings 100 percent"; face.lifetime = .keepAlways; add(face)
    }
    func testDenseRowsWidgetRetainsSixAccountsAndOpensAccount() {
        checkDenseRowsWidget(nativeProviders: false)
    }
    func testDenseRowsWidgetWithDevinAndAmp() {
        checkDenseRowsWidget(nativeProviders: true)
    }
    private func checkDenseRowsWidget(nativeProviders: Bool) {
        let app = XCUIApplication(); app.launchArguments = ["--widget-fixture", nativeProviders ? "--native-provider-fixture" : "--perplexity-count-fixture"]; app.launch()
        XCTAssertTrue(app.buttons["compact-mode"].waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)
        let home = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        clearFixtureWidgets(home)
        let visibleIcon = NSPredicate { _, _ in home.icons.matching(identifier: "Safari").allElementsBoundByIndex.contains { $0.isHittable } }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: visibleIcon, object: nil)], timeout: 10), .completed)
        let icon = home.icons.matching(identifier: "Safari").allElementsBoundByIndex.first { $0.isHittable }!
        icon.press(forDuration: 1.2)
        XCTAssertTrue(home.buttons["Edit Home Screen"].waitForExistence(timeout: 5))
        home.buttons["Edit Home Screen"].tap()
        home.buttons["Edit"].tap(); home.buttons["Add Widget"].tap()
        let search = home.searchFields["Search Widgets"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("Requota")
        let result = home.buttons["Requota"].firstMatch
        if result.waitForExistence(timeout: 3) { result.tap() }
        else { home.staticTexts["Requota"].firstMatch.tap() }
        home.swipeLeft(); home.swipeLeft(); home.swipeLeft()
        let addWidget = home.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Add Widget")).firstMatch
        XCTAssertTrue(addWidget.waitForExistence(timeout: 5))
        addWidget.tap()
        if home.buttons["Done"].waitForExistence(timeout: 5) { home.buttons["Done"].tap() }
        let widget = home.descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND value == %@", "Requota", "Widget")).allElementsBoundByIndex.filter { $0.isHittable }.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }!
        XCTAssertTrue(widget.waitForExistence(timeout: 5))
        print("WIDGET TARGET " + widget.debugDescription)
        widget.press(forDuration: 1.2)
        XCTAssertTrue(home.buttons["Edit Widget"].waitForExistence(timeout: 5))
        home.buttons["Edit Widget"].tap()
        print("DENSE WIDGET EDITOR\n" + home.debugDescription)
        let editorShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); editorShot.name = "Dense widget editor"; editorShot.lifetime = .keepAlways; add(editorShot)
        let addAccount = home.buttons["editor.list.add-item"].firstMatch
        XCTAssertTrue(addAccount.waitForExistence(timeout: 20))
        addAccount.tap()
        XCTAssertTrue(home.staticTexts["Personal"].waitForExistence(timeout: 10))
        home.staticTexts["Personal"].firstMatch.tap()
        XCTAssertTrue(addAccount.waitForExistence(timeout: 10)); addAccount.tap()
        XCTAssertTrue(home.staticTexts["Work"].waitForExistence(timeout: 10))
        home.staticTexts["Work"].firstMatch.tap()
        for name in ["Research", "Mac mini", "Travel", "Studio"] {
            if !addAccount.isHittable { home.tables.firstMatch.swipeUp() }
            XCTAssertTrue(addAccount.waitForExistence(timeout: 10)); addAccount.tap()
            XCTAssertTrue(home.staticTexts[name].waitForExistence(timeout: 10))
            home.staticTexts[name].firstMatch.tap()
        }
        let rows = home.cells.containing(.staticText, identifier: "Rows").firstMatch
        if !rows.isHittable { home.tables.firstMatch.swipeUp() }
        XCTAssertTrue(rows.waitForExistence(timeout: 10)); rows.buttons.firstMatch.tap()
        XCTAssertTrue(home.buttons["6 accounts"].waitForExistence(timeout: 10)); home.buttons["6 accounts"].tap()
        XCUIDevice.shared.press(.home)
        app.terminate()
        let studio = home.staticTexts["Studio"].firstMatch
        XCTAssertTrue(studio.waitForExistence(timeout: 15))
        XCTAssertTrue(home.staticTexts[nativeProviders ? "Credits: $5.00" : "3 left"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(home.staticTexts["No accounts"].isHittable)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = nativeProviders ? "Six account rows with Devin and Amp after app termination" : "Six account rows with Perplexity count after app termination"; shot.lifetime = .keepAlways; add(shot)
        home.staticTexts[nativeProviders ? "Studio" : "Work"].firstMatch.tap()
        XCTAssertTrue(app.buttons["configure-display"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars[nativeProviders ? "Studio" : "Work"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)

    }

}
