import XCTest

final class EyeballsUITests: XCTestCase {
    func testAllProviderConnectionsAndCancellation() {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.buttons["connect-first"].waitForExistence(timeout: 10))
        app.buttons["connect-first"].tap()
        app.buttons["connect-codex"].tap()
        XCTAssertTrue(app.buttons["Continue with ChatGPT"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["independent-connections"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["connect-claude"].waitForExistence(timeout: 5))
        app.buttons["connect-claude"].tap()
        XCTAssertTrue(app.buttons["Continue with Claude"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["independent-connections"].exists)
        app.buttons["Cancel"].tap()
        app.buttons["connect-grok"].tap()
        XCTAssertTrue(app.buttons["Continue with Grok"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap(); app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["connect-first"].exists)
    }
    func testPreviewNavigationAndExitDoNotLeaveFakeConnections() {
        let app = XCUIApplication(); app.launchArguments = ["--demo"]; app.launch()
        XCTAssertTrue(app.staticTexts["Preview · sample accounts"].waitForExistence(timeout: 10))
        app.buttons["account-Personal"].tap()
        XCTAssertTrue(app.buttons["Edit name, workstream & reminders"].waitForExistence(timeout: 5))
        app.buttons["Edit name, workstream & reminders"].tap()
        let name = app.textFields["account-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Exit preview"].tap()
        XCTAssertTrue(app.buttons["connect-first"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Settings"].tap()
        app.buttons["Add a widget"].tap()
        XCTAssertTrue(app.staticTexts["A glance is enough."].waitForExistence(timeout: 5))
    }
    func testSystemAuthenticationPresentation() {
        let app = XCUIApplication(); app.launch()
        app.buttons["connect-first"].tap(); app.buttons["connect-codex"].tap()
        app.buttons["Continue with ChatGPT"].tap()
        let prompt = app.alerts.firstMatch
        if prompt.waitForExistence(timeout: 5), prompt.buttons["Continue"].exists { prompt.buttons["Continue"].tap() }
        let service = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        XCTAssertTrue(service.buttons["Close"].waitForExistence(timeout: 10))
        XCTAssertTrue((service.buttons["URL"].value as? String)?.contains("auth.openai.com") == true)
        XCTAssertTrue(service.textFields["Email address"].waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "System authentication — no credentials entered"
        screenshot.lifetime = .keepAlways; add(screenshot)
        service.buttons["Close"].tap()
        XCTAssertTrue(app.staticTexts["Sign-in was cancelled. Your saved accounts are unchanged."].waitForExistence(timeout: 5))
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
            let prompt = app.alerts.firstMatch
            if prompt.waitForExistence(timeout: 3), prompt.buttons["Continue"].exists { prompt.buttons["Continue"].tap() }
            let service = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
            XCTAssertTrue(service.buttons["Close"].waitForExistence(timeout: 15))
            let address = service.buttons["URL"].value as? String ?? ""
            XCTAssertTrue(provider == "Claude" ? address.contains("claude.") : address.contains("x.ai"), address)
            XCTAssertTrue(service.webViews.firstMatch.waitForExistence(timeout: 15))
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = provider + " provider login — no credentials entered"
            screenshot.lifetime = .keepAlways; add(screenshot)
            service.buttons["Close"].tap()
            XCTAssertTrue(app.staticTexts["Sign-in was cancelled. Your saved accounts are unchanged."].waitForExistence(timeout: 5))
            app.buttons["Cancel"].tap()
        }
    }
}
