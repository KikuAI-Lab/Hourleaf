import Foundation
import XCTest

final class QuickSurfacesLocalizationContractM4Tests: XCTestCase {
    func testExtensionCatalogsHaveExactKeyAndPlaceholderParity() throws {
        let root = repositoryRoot
        let localeDirectories = ["en.lproj", "ru.lproj", "uk.lproj"]
        let catalogs = try localeDirectories.map { locale -> (String, [String: String]) in
            let url = root
                .appendingPathComponent("HourleafQuickSurfaces")
                .appendingPathComponent(locale)
                .appendingPathComponent("Localizable.strings")
            return (locale, try parseStringsFile(at: url))
        }

        guard let english = catalogs.first(where: { $0.0 == "en.lproj" })?.1 else {
            XCTFail("English extension catalog is missing")
            return
        }

        for (locale, catalog) in catalogs {
            XCTAssertEqual(
                Set(catalog.keys),
                Set(english.keys),
                "Extension localization keys differ for \(locale)"
            )
            for key in english.keys {
                XCTAssertEqual(
                    placeholders(in: english[key] ?? ""),
                    placeholders(in: catalog[key] ?? ""),
                    "Placeholder drift for \(key) in \(locale)"
                )
            }
        }
    }

    func testExtensionCatalogsDoNotMentionPrivateStorageOrLedgerDetails() throws {
        let root = repositoryRoot
        for locale in ["en.lproj", "ru.lproj", "uk.lproj"] {
            let url = root
                .appendingPathComponent("HourleafQuickSurfaces")
                .appendingPathComponent(locale)
                .appendingPathComponent("Localizable.strings")
            let contents = try String(contentsOf: url, encoding: .utf8).lowercased()
            for forbidden in ["core data", "application group", "json", "ledger", "note", "history"] {
                XCTAssertFalse(contents.contains(forbidden), "\(locale) contains private term \(forbidden)")
            }
        }
    }

    private func parseStringsFile(at url: URL) throws -> [String: String] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        var values: [String: String] = [:]
        let pattern = #"^\s*"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)"\s*;\s*$"#
        let expression = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        for match in expression.matches(in: contents, options: [], range: range) {
            guard
                let keyRange = Range(match.range(at: 1), in: contents),
                let valueRange = Range(match.range(at: 2), in: contents)
            else { continue }
            let key = String(contents[keyRange]).replacingOccurrences(of: #"\""#, with: "\"")
            let value = String(contents[valueRange]).replacingOccurrences(of: #"\""#, with: "\"")
            values[key] = value
        }
        return values
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // QuickSurfaces
            .deletingLastPathComponent() // HourleafTests
            .deletingLastPathComponent()
    }

    private func placeholders(in value: String) -> [String] {
        let pattern = #"%(?:\d+\$)?[@d]"#
        let expression = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.matches(in: value, options: [], range: range).compactMap {
            Range($0.range, in: value).map { String(value[$0]) }
        }
    }
}
