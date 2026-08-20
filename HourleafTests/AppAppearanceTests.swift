import Foundation
import SwiftUI
import XCTest
@testable import Hourleaf

final class AppAppearanceTests: XCTestCase {
    func testStoredValuesResolveToExpectedAppearance() {
        XCTAssertEqual(AppAppearance(storedValue: "system"), .system)
        XCTAssertEqual(AppAppearance(storedValue: "light"), .light)
        XCTAssertEqual(AppAppearance(storedValue: "dark"), .dark)
        XCTAssertEqual(AppAppearance(storedValue: "unexpected"), .system)
    }

    func testAppearanceMapsToPreferredColorScheme() {
        XCTAssertNil(AppAppearance.system.colorScheme)
        XCTAssertEqual(AppAppearance.light.colorScheme, .light)
        XCTAssertEqual(AppAppearance.dark.colorScheme, .dark)
    }

    func testAppearanceCopyExistsInEverySupportedLanguage() throws {
        let expected: [String: [String: String]] = [
            "en": [
                "settings.appearance.title": "Appearance",
                "settings.appearance.mode": "Theme",
                "settings.appearance.system": "Match iPhone",
                "settings.appearance.light": "Light",
                "settings.appearance.dark": "Dark"
            ],
            "ru": [
                "settings.appearance.title": "Оформление",
                "settings.appearance.mode": "Тема",
                "settings.appearance.system": "Как на iPhone",
                "settings.appearance.light": "Светлая",
                "settings.appearance.dark": "Тёмная"
            ],
            "uk": [
                "settings.appearance.title": "Вигляд",
                "settings.appearance.mode": "Тема",
                "settings.appearance.system": "Як на iPhone",
                "settings.appearance.light": "Світла",
                "settings.appearance.dark": "Темна"
            ]
        ]

        for (language, expectedValues) in expected {
            let url = repositoryRoot
                .appendingPathComponent("Hourleaf/\(language).lproj/Localizable.strings")
            let data = try Data(contentsOf: url)
            let values = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
            )
            for (key, expectedValue) in expectedValues {
                XCTAssertEqual(values[key], expectedValue, "Unexpected \(language) value for \(key)")
            }
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
