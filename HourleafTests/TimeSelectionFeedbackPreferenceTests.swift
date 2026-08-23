import Foundation
import XCTest
@testable import Hourleaf

final class TimeSelectionFeedbackPreferenceTests: XCTestCase {
    func testPreferenceDefaultsToEnabledAndPreservesExplicitValue() throws {
        let suiteName = "TimeSelectionFeedbackPreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(TimeSelectionFeedbackPreference.storedValue(in: defaults))

        defaults.set(false, forKey: TimeSelectionFeedbackPreference.storageKey)
        XCTAssertFalse(TimeSelectionFeedbackPreference.storedValue(in: defaults))

        defaults.set(true, forKey: TimeSelectionFeedbackPreference.storageKey)
        XCTAssertTrue(TimeSelectionFeedbackPreference.storedValue(in: defaults))
    }

    func testFeedbackRequiresChangedManualSelectionWhileEnabled() {
        XCTAssertTrue(
            TimeSelectionFeedbackPreference.shouldRequestFeedback(
                for: .userInteraction,
                isEnabled: true,
                previousValue: 1,
                selectedValue: 2
            )
        )
        XCTAssertFalse(
            TimeSelectionFeedbackPreference.shouldRequestFeedback(
                for: .userInteraction,
                isEnabled: false,
                previousValue: 1,
                selectedValue: 2
            )
        )
        XCTAssertFalse(
            TimeSelectionFeedbackPreference.shouldRequestFeedback(
                for: .userInteraction,
                isEnabled: true,
                previousValue: 1,
                selectedValue: 1
            )
        )
        XCTAssertFalse(
            TimeSelectionFeedbackPreference.shouldRequestFeedback(
                for: .externalUpdate,
                isEnabled: true,
                previousValue: 1,
                selectedValue: 2
            )
        )
    }

    func testSettingsCopyExistsInEverySupportedLanguage() throws {
        let expected: [String: [String: String]] = [
            "en": [
                "settings.time_selection_feedback": "Light vibration",
                "settings.time_selection_feedback_help":
                    "A light tap when you choose hours, minutes, or Bible studies."
            ],
            "ru": [
                "settings.time_selection_feedback": "Лёгкая вибрация",
                "settings.time_selection_feedback_help":
                    "Лёгкий отклик при выборе часов, минут или числа изучений Библии."
            ],
            "uk": [
                "settings.time_selection_feedback": "Легка вібрація",
                "settings.time_selection_feedback_help":
                    "Легкий відгук під час вибору годин, хвилин або кількості вивчень Біблії."
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
