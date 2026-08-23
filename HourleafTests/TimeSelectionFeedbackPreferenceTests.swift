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
                "settings.time_selection_feedback": "Vibrate when choosing time",
                "settings.time_selection_feedback_help":
                    "iPhone gives a light vibration when hours or minutes change."
            ],
            "ru": [
                "settings.time_selection_feedback": "Вибрация при выборе времени",
                "settings.time_selection_feedback_help":
                    "iPhone слегка вибрирует при изменении часов или минут."
            ],
            "uk": [
                "settings.time_selection_feedback": "Вібрація під час вибору часу",
                "settings.time_selection_feedback_help":
                    "iPhone легко вібрує під час зміни годин або хвилин."
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
