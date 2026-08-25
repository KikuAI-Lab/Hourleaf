import Foundation
import XCTest
@testable import Hourleaf

final class QuickSurfacePacketCM4Tests: XCTestCase {
    func testQuickEntryURLBuildsAndMatchesOnlyTheExactRoute() throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "m4-quick-entry-url")
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let bundle = try makeBundle(
            root: root,
            values: [HourleafQuickEntryURL.infoKey: "hourleaf"]
        )

        XCTAssertEqual(HourleafQuickEntryURL.resolveScheme(bundle: bundle), "hourleaf")
        let quickEntryURL = try XCTUnwrap(HourleafQuickEntryURL.makeURL(bundle: bundle))
        XCTAssertEqual(quickEntryURL.absoluteString, "hourleaf://quick-entry")
        XCTAssertTrue(HourleafQuickEntryURL.matches(url: quickEntryURL, bundle: bundle))
        XCTAssertTrue(HourleafQuickEntryURL.matches(quickEntryURL, bundle: bundle))
        XCTAssertFalse(
            HourleafQuickEntryURL.matches(
                url: URL(string: "hourleaf://quick-entry?source=widget")!,
                bundle: bundle
            )
        )
        XCTAssertFalse(
            HourleafQuickEntryURL.matches(
                url: URL(string: "hourleaf://quick-entry/")!,
                bundle: bundle
            )
        )
        XCTAssertFalse(
            HourleafQuickEntryURL.matches(
                url: URL(string: "Hourleaf://quick-entry")!,
                bundle: bundle
            )
        )
    }

    func testQuickEntryURLRejectsNonLowercaseOrMalformedSchemes() throws {
        XCTAssertTrue(HourleafQuickEntryURL.isValidScheme("hourleaf"))
        XCTAssertTrue(HourleafQuickEntryURL.isValidScheme("hourleaf+local"))
        XCTAssertFalse(HourleafQuickEntryURL.isValidScheme("Hourleaf"))
        XCTAssertFalse(HourleafQuickEntryURL.isValidScheme("1hourleaf"))
        XCTAssertFalse(HourleafQuickEntryURL.isValidScheme("hour leaf"))
        XCTAssertFalse(HourleafQuickEntryURL.isValidScheme("hourleaf://"))

        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "m4-quick-entry-invalid")
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        for value in ["Hourleaf", " hourleaf", "hourleaf ", "", "1hourleaf"] {
            let bundle = try makeBundle(
                root: root,
                name: "\(value.hashValue).bundle",
                values: [HourleafQuickEntryURL.infoKey: value]
            )
            XCTAssertNil(HourleafQuickEntryURL.resolveScheme(bundle: bundle), value)
            XCTAssertNil(HourleafQuickEntryURL.makeURL(bundle: bundle), value)
        }
    }

    func testDisplayReducerShowsCurrentTotalsAndRedactsPreviousMonth() throws {
        let state = try shownState(monthKey: "2026-08", timeZoneIdentifier: "Europe/Uzhgorod")
        let current = date(year: 2026, month: 8, day: 15, timeZoneIdentifier: "Europe/Uzhgorod")
        let nextMonth = date(year: 2026, month: 9, day: 1, timeZoneIdentifier: "Europe/Uzhgorod")

        XCTAssertEqual(
            QuickSurfaceDisplayReducerV1.reduce(state: state, asOf: current).totals,
            .shown(
                monthKey: "2026-08",
                serviceMinutes: 125,
                creditMinutes: 7,
                bibleStudyCount: 4,
                serviceYearMinutes: 24_750,
                serviceYearTargetMinutes: 36_000
            )
        )

        let stale = QuickSurfaceDisplayReducerV1.reduce(state: state, asOf: nextMonth)
        XCTAssertEqual(stale.availability, .ready)
        XCTAssertEqual(stale.totals, .absent)
        XCTAssertEqual(stale.timer, .idle)
    }

    func testDisplayReducerUsesProjectionTimezoneAtCivilMonthBoundary() throws {
        let state = try shownState(monthKey: "2026-08", timeZoneIdentifier: "Pacific/Kiritimati")
        let beforeMidnightUTC = date(
            year: 2026,
            month: 8,
            day: 31,
            hour: 9,
            timeZoneIdentifier: "UTC"
        )
        let afterMidnightUTC = date(
            year: 2026,
            month: 8,
            day: 31,
            hour: 10,
            timeZoneIdentifier: "UTC"
        )

        XCTAssertEqual(
            QuickSurfaceDisplayReducerV1.reduce(state: state, asOf: beforeMidnightUTC).totals,
            .shown(
                monthKey: "2026-08",
                serviceMinutes: 125,
                creditMinutes: 7,
                bibleStudyCount: 4,
                serviceYearMinutes: 24_750,
                serviceYearTargetMinutes: 36_000
            )
        )
        XCTAssertEqual(
            QuickSurfaceDisplayReducerV1.reduce(state: state, asOf: afterMidnightUTC).totals,
            .absent
        )
    }

    func testInvalidProjectionTimezoneFailsClosedBeforeDisplay() throws {
        XCTAssertThrowsError(
            try QuickSurfaceProjectionV1(
                privacyMode: .showTotals,
                monthKey: "2026-08",
                timeZoneIdentifier: "Mars/Phobos",
                serviceMinutes: 1,
                creditMinutes: 0,
                generatedAtEpochSeconds: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? QuickSurfaceStateCodecError,
                .invalidValue("projection.timeZoneIdentifier must be an existing IANA identifier")
            )
        }
    }

    private func shownState(
        monthKey: String,
        timeZoneIdentifier: String
    ) throws -> QuickSurfaceStateV1 {
        QuickSurfaceStateV1(
            revision: 1,
            projection: try QuickSurfaceProjectionV1(
                privacyMode: .showTotals,
                monthKey: monthKey,
                timeZoneIdentifier: timeZoneIdentifier,
                serviceMinutes: 125,
                creditMinutes: 7,
                bibleStudyCount: 4,
                serviceYearMinutes: 24_750,
                serviceYearTargetMinutes: 36_000,
                generatedAtEpochSeconds: 1
            ),
            timerEnabled: true,
            timer: .idle
        )
    }

    private func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 12,
        timeZoneIdentifier: String
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        return calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour)
        )!
    }

    private func makeBundle(
        root: URL,
        name: String = "quick-entry.bundle",
        values: [String: Any]
    ) throws -> Bundle {
        let bundleURL = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let plistURL = bundleURL.appendingPathComponent("Info.plist")
        try (values as NSDictionary).write(to: plistURL)
        guard let bundle = Bundle(url: bundleURL) else {
            throw NSError(domain: "QuickSurfacePacketCM4Tests", code: 1)
        }
        return bundle
    }
}
