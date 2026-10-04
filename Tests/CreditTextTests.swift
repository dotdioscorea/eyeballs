import XCTest
@testable import Requota

final class CreditTextTests: XCTestCase {
    func testCreditDisplayCapsDecimalsWithoutChangingSavedPrecision() throws {
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(CreditText.formatted("1234.567891234", locale: locale), "1,234.57")
        XCTAssertEqual(CreditText.formatted("0.5000", locale: locale), "0.5")
        XCTAssertEqual(CreditText.formatted("15.00", locale: locale), "15")
        XCTAssertEqual(CreditText.formatted("0", locale: locale), "0")
        XCTAssertEqual(CreditText.formatted("0.00000123", locale: locale), "<0.01")
        XCTAssertEqual(CreditText.formatted("1.23e-6", locale: locale), "<0.01")
        XCTAssertEqual(CreditText.formatted("-0.00000123", locale: locale), ">−0.01")
        let snapshot = UsageSnapshot(creditBalance: "1234.567891234")
        XCTAssertEqual(try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(snapshot)).creditBalance, "1234.567891234")
    }
    func testCreditDisplayRetainsProviderCurrencyAndNonNumericLabels() {
        for value in ["$5.00", "£1.25", "Unlimited", "12 credits", "NaN", "12garbage"] { XCTAssertEqual(CreditText.formatted(value), value) }
        XCTAssertEqual(CreditText.formatted("1234.5678", locale: Locale(identifier: "de_DE")), "1.234,57")
    }
}
