import XCTest
@testable import Eyeballs

final class CredentialVaultTests: XCTestCase {
    func testKeychainRecordsAreIndependentAndRemovalClearsOnlyOne() throws {
        let vault = CredentialVault(); let first = UUID(), second = UUID()
        defer { try? vault.delete(id: first); try? vault.delete(id: second) }
        let a = Fixture.credential("keychain-a"), b = Fixture.credential("keychain-b")
        try vault.save(a, id: first); try vault.save(b, id: second)
        XCTAssertEqual(try vault.load(id: first), a)
        XCTAssertEqual(try vault.load(id: second), b)
        var rotated = a; rotated.accessToken = "fixture-rotated"
        try vault.save(rotated, id: first)
        XCTAssertEqual(try vault.load(id: first), rotated)
        XCTAssertEqual(try vault.load(id: second), b)
        try vault.delete(id: first)
        XCTAssertNil(try vault.load(id: first))
        XCTAssertEqual(try vault.load(id: second), b)
    }
}
