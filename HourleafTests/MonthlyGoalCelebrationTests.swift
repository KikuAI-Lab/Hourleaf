import XCTest
@testable import Hourleaf

@MainActor
final class MonthlyGoalCelebrationTests: XCTestCase {
    func testTrackerCelebratesCombinedServiceAndCreditWhenThresholdIsCrossed() {
        withDefaults { defaults in
            let tracker = MonthlyGoalCelebrationTracker(defaults: defaults)
            let month = MonthKey(year: 2026, month: 9)

            XCTAssertFalse(tracker.observe(
                month: month,
                serviceMinutes: 49 * 60,
                creditMinutes: 0,
                allowsCelebration: true
            ))
            XCTAssertTrue(tracker.observe(
                month: month,
                serviceMinutes: 49 * 60,
                creditMinutes: 60,
                allowsCelebration: true
            ))
        }
    }

    func testTrackerDoesNotCelebrateAnExistingTotalOrRepeatWithinMonth() {
        withDefaults { defaults in
            let tracker = MonthlyGoalCelebrationTracker(defaults: defaults)
            let month = MonthKey(year: 2026, month: 9)

            XCTAssertFalse(tracker.observe(
                month: month,
                serviceMinutes: 50 * 60,
                creditMinutes: 0,
                allowsCelebration: true
            ))
            XCTAssertFalse(tracker.observe(
                month: month,
                serviceMinutes: 51 * 60,
                creditMinutes: 0,
                allowsCelebration: true
            ))
        }
    }

    func testTrackerDoesNotRepeatAfterTotalDropsAndCrossesAgain() {
        withDefaults { defaults in
            let tracker = MonthlyGoalCelebrationTracker(defaults: defaults)
            let month = MonthKey(year: 2026, month: 9)

            XCTAssertFalse(tracker.observe(
                month: month,
                serviceMinutes: 49 * 60,
                creditMinutes: 0,
                allowsCelebration: true
            ))
            XCTAssertTrue(tracker.observe(
                month: month,
                serviceMinutes: 50 * 60,
                creditMinutes: 0,
                allowsCelebration: true
            ))
            XCTAssertFalse(tracker.observe(
                month: month,
                serviceMinutes: 49 * 60,
                creditMinutes: 0,
                allowsCelebration: true
            ))
            XCTAssertFalse(tracker.observe(
                month: month,
                serviceMinutes: 50 * 60,
                creditMinutes: 0,
                allowsCelebration: true
            ))
        }
    }

    func testTrackerRecordsSuppressedCrossingWithoutReplayingItLater() {
        withDefaults { defaults in
            let tracker = MonthlyGoalCelebrationTracker(defaults: defaults)
            let month = MonthKey(year: 2026, month: 9)

            XCTAssertFalse(tracker.observe(
                month: month,
                serviceMinutes: 49 * 60,
                creditMinutes: 0,
                allowsCelebration: true
            ))
            XCTAssertFalse(tracker.observe(
                month: month,
                serviceMinutes: 50 * 60,
                creditMinutes: 0,
                allowsCelebration: false
            ))
            XCTAssertFalse(tracker.observe(
                month: month,
                serviceMinutes: 50 * 60 + 1,
                creditMinutes: 0,
                allowsCelebration: true
            ))
        }
    }

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "MonthlyGoalCelebrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }
}
