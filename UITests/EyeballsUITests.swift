import XCTest

final class EyeballsUITests: XCTestCase {
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
    func testReleaseDemoAndRestoration() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixture", "--exit-demo-test"]; app.launch()
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 10)); app.tabBars.buttons["Settings"].tap()
        app.buttons["start-demo"].tap()
        XCTAssertTrue(app.buttons["exit-demo"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Settings"].tap(); app.buttons["Reset sample data"].tap()
        app.tabBars.buttons["Accounts"].tap()
        app.buttons["sort-accounts"].tap(); app.buttons["Custom order"].tap()
        XCTAssertTrue(app.buttons["account-Demo · Personal"].waitForExistence(timeout: 5))
        app.buttons["layout-cards"].tap()
        let cards = XCTAttachment(screenshot: app.screenshot()); cards.name = "Release demo cards"; cards.lifetime = .keepAlways; add(cards)
        app.buttons["compact-mode"].tap()
        let compact = XCTAttachment(screenshot: app.screenshot()); compact.name = "Release demo compact"; compact.lifetime = .keepAlways; add(compact)
        app.buttons["layout-tiles"].tap()
        let dashboard = XCTAttachment(screenshot: app.screenshot()); dashboard.name = "Release demo tiles"; dashboard.lifetime = .keepAlways; add(dashboard)
        app.buttons["account-Demo · Personal"].tap()
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
        XCTAssertFalse(app.buttons["account-Demo · Personal"].exists)
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
    func testHistorySelectionEventsAndCalendar() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixture", "--exit-demo-test"]; app.launch()
        app.tabBars.buttons["Settings"].tap(); app.buttons["start-demo"].tap()
        app.tabBars.buttons["Settings"].tap(); app.buttons["Reset sample data"].tap()
        app.tabBars.buttons["Accounts"].tap(); app.buttons["account-Demo · Personal"].tap()
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
        XCTAssertTrue(app.staticTexts["Credits"].exists); XCTAssertTrue(app.staticTexts["15.00"].exists)
        XCTAssertTrue(app.staticTexts["Weekly allowance exhausted"].exists)
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
            XCTAssertTrue(service.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", "Close", "Cancel")).firstMatch.waitForExistence(timeout: 10))
            XCTAssertTrue(service.textFields["Email address"].waitForExistence(timeout: 15))
            XCTAssertTrue((service.buttons["URL"].value as? String)?.contains("auth.openai.com") == true)
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "System authentication \(button) — no credentials entered"
            screenshot.lifetime = .keepAlways; add(screenshot)
            service.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", "Close", "Cancel")).firstMatch.tap()
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
        if !app.buttons["account-Demo · Work"].exists { app.swipeUp() }
        app.buttons["account-Demo · Work"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)))
        XCTAssertTrue(app.staticTexts["Usage credits"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Share of weekly usage"].exists)
        XCTAssertTrue(app.staticTexts["Claude Code"].exists)
        let claude = XCTAttachment(screenshot: app.screenshot()); claude.name = "Claude spending and app breakdown"; claude.lifetime = .keepAlways; add(claude)
        app.navigationBars.buttons["Requota"].tap()
        app.buttons["account-Demo · Personal"].tap()
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
        home.cells.containing(.staticText, identifier: "Personal").allElementsBoundByIndex.first { $0.isHittable }!.tap()
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Widget configured with Personal"; shot.lifetime = .keepAlways; add(shot)
        XCUIDevice.shared.press(.home); app.terminate()
        XCTAssertTrue(home.staticTexts["Personal"].firstMatch.waitForExistence(timeout: 15))
        let face = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); face.name = "Small widget four rings 100 percent"; face.lifetime = .keepAlways; add(face)
    }
    func testDenseRowsWidgetRetainsSixAccountsAndOpensAccount() {
        let app = XCUIApplication(); app.launchArguments = ["--widget-fixture"]; app.launch()
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
        home.cells.containing(.staticText, identifier: "Personal").allElementsBoundByIndex.first { $0.isHittable }!.tap()
        XCTAssertTrue(addAccount.waitForExistence(timeout: 10)); addAccount.tap()
        XCTAssertTrue(home.staticTexts["Work"].waitForExistence(timeout: 10))
        home.cells.containing(.staticText, identifier: "Work").allElementsBoundByIndex.first { $0.isHittable }!.tap()
        for name in ["Research", "Mac mini", "Travel", "Studio"] {
            if !addAccount.isHittable { home.tables.firstMatch.swipeUp() }
            XCTAssertTrue(addAccount.waitForExistence(timeout: 10)); addAccount.tap()
            XCTAssertTrue(home.staticTexts[name].waitForExistence(timeout: 10))
            home.cells.containing(.staticText, identifier: name).allElementsBoundByIndex.first { $0.isHittable }!.tap()
        }
        let rows = home.cells.containing(.staticText, identifier: "Rows").firstMatch
        if !rows.isHittable { home.tables.firstMatch.swipeUp() }
        XCTAssertTrue(rows.waitForExistence(timeout: 10)); rows.buttons.firstMatch.tap()
        XCTAssertTrue(home.buttons["6 accounts"].waitForExistence(timeout: 10)); home.buttons["6 accounts"].tap()
        XCUIDevice.shared.press(.home)
        app.terminate()
        let studio = home.staticTexts["Studio"].firstMatch
        XCTAssertTrue(studio.waitForExistence(timeout: 15))
        XCTAssertFalse(home.staticTexts["No accounts"].isHittable)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Six account rows after app termination"; shot.lifetime = .keepAlways; add(shot)
        home.staticTexts["Work"].firstMatch.tap()
        XCTAssertTrue(app.buttons["configure-display"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Work"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)

    }

}
