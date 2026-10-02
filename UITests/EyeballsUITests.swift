import XCTest

final class EyeballsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    private func allowSystemSignIn() {
        // Shared sessions ask iOS for permission to use existing browser data.
        // This alert belongs to SpringBoard, rather than the app under test.
        let prompt = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if prompt.waitForExistence(timeout: 5), prompt.buttons["Continue"].exists {
            prompt.buttons["Continue"].tap()
        }
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
    func testCompactDisplayConfigurationAndCopyCleanup() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixture"]; app.launch()
        XCTAssertTrue(app.buttons["compact-mode"].waitForExistence(timeout: 10))
        if app.buttons["compact-mode"].value as? String != "On" { app.buttons["compact-mode"].tap() }
        XCTAssertTrue(app.buttons["sort-accounts"].exists)
        app.buttons["sort-accounts"].tap()
        app.buttons["Name"].tap()
        app.textFields["search-accounts"].tap(); app.textFields["search-accounts"].typeText("Personal")
        app.buttons["account-Personal"].tap()
        XCTAssertFalse(app.buttons["Refresh usage"].exists)
        app.buttons["configure-display"].tap()
        XCTAssertTrue(app.switches["metric-week:time"].waitForExistence(timeout: 5))
        app.switches["metric-week:time"].tap()
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Weekly time"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Settings"].tap()
        XCTAssertFalse(app.buttons["Add a widget"].exists)
        XCTAssertFalse(app.buttons["Preview with sample accounts"].exists)
        XCTAssertTrue(app.buttons["Source code"].exists)
        app.buttons["Report a problem"].tap()
        app.switches["include-debug-bundle"].tap()
        XCTAssertTrue(app.buttons["Save or share debug bundle"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["compact-mode"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["compact-mode"].value as? String, "On")
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
    func testWidgetAccountPickerStaysOpenAndSelectsAccount() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixture"]; app.launch()
        XCTAssertTrue(app.buttons["compact-mode"].waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)
        let home = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let icon = home.icons["Eyeballs"].firstMatch
        XCTAssertTrue(icon.waitForExistence(timeout: 10))
        icon.press(forDuration: 1.2)
        XCTAssertTrue(home.buttons["Edit Home Screen"].waitForExistence(timeout: 5))
        home.buttons["Edit Home Screen"].tap()
        home.buttons["Edit"].tap(); home.buttons["Add Widget"].tap()
        let search = home.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("Eyeballs")
        print("WIDGET GALLERY", home.debugDescription)
        let result = home.buttons["Eyeballs"].firstMatch
        if result.waitForExistence(timeout: 3) { result.tap() }
        else { home.staticTexts["Eyeballs"].firstMatch.tap() }
        XCTAssertTrue(home.buttons["Add Widget"].waitForExistence(timeout: 5))
        home.buttons["Add Widget"].tap()
        if home.buttons["Done"].waitForExistence(timeout: 5) { home.buttons["Done"].tap() }
        print("ADDED WIDGET", home.debugDescription)
        let widget = home.otherElements.matching(NSPredicate(format: "label CONTAINS %@", "Account")).firstMatch
        XCTAssertTrue(widget.waitForExistence(timeout: 5))
        widget.press(forDuration: 1.2)
        XCTAssertTrue(home.buttons["Edit Widget"].waitForExistence(timeout: 5))
        home.buttons["Edit Widget"].tap()
        print("WIDGET EDITOR", home.debugDescription)
        home.buttons["Account"].firstMatch.tap()
        XCTAssertTrue(home.staticTexts["Personal"].waitForExistence(timeout: 5))
        home.staticTexts["Personal"].tap()
        print("WIDGET SELECTION", home.debugDescription)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Widget configured with Personal"; shot.lifetime = .keepAlways; add(shot)
    }

}
