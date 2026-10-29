import XCTest
@testable import FeedingCore

final class LocalizationTests: XCTestCase {
    let german = Locale(identifier: "de_DE")
    let english = Locale(identifier: "en_GB")

    func testGermanAndEnglishFormatsPreserveValuesAndPluralGrammar() {
        XCTAssertEqual(L10n.format("%dh %dm", 2, 5, locale: german), "2 Std. 5 Min.")
        XCTAssertEqual(L10n.format("%dm %ds", 3, 7, locale: german), "3 Min. 7 Sek.")
        XCTAssertEqual(L10n.format("Yesterday: %d ml", 125, locale: german), "Gestern: 125 ml")
        XCTAssertEqual(L10n.format("%d feed · %d ml by bottle · Grouped by start date", 1, 60, locale: german),
                       "1 Mahlzeit · 60 ml per Fläschchen · Nach Beginn gruppiert")
        XCTAssertEqual(L10n.format("%d feeds · %d ml by bottle · Grouped by start date", 2, 150, locale: german),
                       "2 Mahlzeiten · 150 ml per Fläschchen · Nach Beginn gruppiert")
        XCTAssertEqual(L10n.format("%dh %dm", 2, 5, locale: english), "2h 5m")
        XCTAssertEqual(L10n.format("Could not save: %@", "Details", locale: german), "Speichern nicht möglich: Details")
    }

    func testUnknownLanguagesFallBackToEnglishAndUnknownMessagesRemainReadable() {
        XCTAssertEqual(L10n.text("History", locale: Locale(identifier: "fr_FR")), "History")
        XCTAssertEqual(L10n.text("History", locale: german), "Verlauf")
        XCTAssertEqual(L10n.text("A system-provided message", locale: german), "A system-provided message")
        XCTAssertEqual(L10n.text("Enter a bottle amount between 1 and 2,000 ml.", locale: german),
                       "Gib eine Fläschchenmenge zwischen 1 und 2.000 ml ein.")
    }

    func testBothCatalogsHaveIdenticalKeysAndCompatibleFormatSpecifiers() throws {
        let resourceBundle = Bundle.module
        func catalog(_ language: String) throws -> [String: String] {
            let url = try XCTUnwrap(resourceBundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
        }
        let en = try catalog("en"), de = try catalog("de")
        XCTAssertGreaterThan(de.count, 180)
        XCTAssertEqual(Set(en.keys), Set(de.keys))
        let pattern = try NSRegularExpression(pattern: #"%(?:\d+\$)?(?:lld|ld|d|@)"#)
        func specifiers(_ value: String) -> [String] {
            pattern.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
                String(value[Range($0.range, in: value)!])
            }.sorted()
        }
        for key in en.keys { XCTAssertEqual(specifiers(en[key]!), specifiers(de[key]!), "Format mismatch for \(key)") }
    }
}
