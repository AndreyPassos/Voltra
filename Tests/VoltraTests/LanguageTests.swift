import XCTest
@testable import Voltra

final class LanguageTests: XCTestCase {
    func testSystemLanguageUsesPortugueseOnlyForPortuguese() {
        XCTAssertEqual(VoltraLanguage.resolve("system", preferred: ["pt-BR"]), "pt")
        XCTAssertEqual(VoltraLanguage.resolve("system", preferred: ["pt-PT"]), "pt")
        XCTAssertEqual(VoltraLanguage.resolve("system", preferred: ["es-BR", "pt-BR"]), "en")
        XCTAssertEqual(VoltraLanguage.resolve("system", preferred: []), "en")
    }
    func testExplicitLanguageOverridesSystemAndUnknownDefaultsToEnglish() {
        XCTAssertEqual(VoltraLanguage.resolve("en", preferred: ["pt-BR"]), "en")
        XCTAssertEqual(VoltraLanguage.resolve("pt", preferred: ["en-US"]), "pt")
        XCTAssertEqual(VoltraLanguage.resolve("invalid", preferred: ["pt-BR"]), "en")
    }
}
