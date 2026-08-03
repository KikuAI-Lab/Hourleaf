import CoreData
import XCTest
@testable import Hourleaf

@MainActor
final class QuickSurfacePreferencesPersistenceTests: XCTestCase {
    func testQuickSurfacePreferencesDefaultToTimerOffAndHiddenTotals() async throws {
        let repository = makeRepository()

        let snapshot = try await repository.ledgerSnapshot()

        XCTAssertEqual(
            snapshot.settingsMetadata.quickSurfacePreferences,
            QuickSurfacePreferences(timerVisible: false, privacyMode: .hideTotals)
        )
    }

    func testQuickSurfacePreferencesAcceptBothExplicitPrivacyModes() async throws {
        let repository = makeRepository()

        try await repository.saveQuickSurfacePreferences(
            QuickSurfacePreferences(timerVisible: true, privacyMode: .showTotals)
        )
        let shownSnapshot = try await repository.ledgerSnapshot()
        XCTAssertEqual(
            shownSnapshot.settingsMetadata.quickSurfacePreferences,
            QuickSurfacePreferences(timerVisible: true, privacyMode: .showTotals)
        )

        try await repository.saveQuickSurfacePreferences(
            QuickSurfacePreferences(timerVisible: false, privacyMode: .hideTotals)
        )
        let hiddenSnapshot = try await repository.ledgerSnapshot()
        XCTAssertEqual(
            hiddenSnapshot.settingsMetadata.quickSurfacePreferences,
            QuickSurfacePreferences(timerVisible: false, privacyMode: .hideTotals)
        )
    }

    func testUnknownWidgetPrivacyValueFallsBackToHiddenTotals() async throws {
        let persistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        let repository = CoreDataLedgerRepository(persistence: persistence)
        _ = try await repository.ledgerSnapshot()

        try setRawQuickSurfaceState(
            persistence: persistence,
            timerVisible: true,
            widgetPrivacyMode: "private"
        )

        let snapshot = try await repository.ledgerSnapshot()

        XCTAssertEqual(snapshot.settingsMetadata.widgetPrivacyMode, "private")
        XCTAssertEqual(
            snapshot.settingsMetadata.quickSurfacePreferences,
            QuickSurfacePreferences(timerVisible: true, privacyMode: .hideTotals)
        )
    }

    func testSavingQuickSurfacePreferencesPreservesUnrelatedSettingsAndReservedMetadata() async throws {
        let persistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        let repository = CoreDataLedgerRepository(persistence: persistence)
        var settings = try await repository.loadSettings()
        settings.reportLanguage = .ukrainian
        settings.creditLabelEnglish = "Field credit"
        settings.creditLabelRussian = "Польовий кредит"
        settings.creditLabelUkrainian = "Польовий кредит"
        settings.ledgerStartMonth = MonthKey(year: 2026, month: 2)
        settings.baselineServiceYearMinutes = 12_345
        settings.baselineServiceYearStart = MonthKey(year: 2025, month: 9)
        settings.openingServiceCarryMinutes = 17
        settings.openingCreditCarryMinutes = 43
        settings.onboardingComplete = true
        try await repository.saveSettings(settings)
        try await repository.savePlanningPreferences(
            PlanningPreferences(isPaceVisible: true, isQuietGapEnabled: true, quietGapDays: 9)
        )
        let expectedPurge = Date(timeIntervalSince1970: 1_700_123_456)
        try setReservedMetadata(
            persistence: persistence,
            syncMode: "icloudPrivate",
            lastPurgeAt: expectedPurge
        )

        try await repository.saveQuickSurfacePreferences(
            QuickSurfacePreferences(timerVisible: true, privacyMode: .showTotals)
        )

        let snapshot = try await repository.ledgerSnapshot()

        XCTAssertEqual(snapshot.settings, settings)
        XCTAssertEqual(snapshot.settingsMetadata.quickSurfacePreferences.privacyMode, .showTotals)
        XCTAssertTrue(snapshot.settingsMetadata.quickSurfacePreferences.timerVisible)
        XCTAssertEqual(snapshot.settingsMetadata.widgetPrivacyMode, WidgetPrivacyMode.showTotals.rawValue)
        XCTAssertTrue(snapshot.settingsMetadata.planningVisible)
        XCTAssertTrue(snapshot.settingsMetadata.quietGapCheckEnabled)
        XCTAssertEqual(snapshot.settingsMetadata.quietGapDays, 9)
        XCTAssertEqual(snapshot.settingsMetadata.syncMode, "icloudPrivate")
        XCTAssertEqual(snapshot.settingsMetadata.lastPurgeAt, expectedPurge)
    }

    func testConcurrentSettingsAndQuickSurfaceSavesDoNotClobberEachOther() async throws {
        let repository = makeRepository()
        var settings = try await repository.loadSettings()
        settings.reportLanguage = .russian
        settings.creditLabelEnglish = "Evening credit"
        settings.ledgerStartMonth = MonthKey(year: 2026, month: 4)
        settings.baselineServiceYearMinutes = 4_567
        settings.baselineServiceYearStart = MonthKey(year: 2025, month: 9)
        settings.openingServiceCarryMinutes = 12
        settings.openingCreditCarryMinutes = 34
        settings.onboardingComplete = true
        let expectedSettings = settings
        let quickPreferences = QuickSurfacePreferences(
            timerVisible: true,
            privacyMode: .showTotals
        )

        async let saveSettings: Void = repository.saveSettings(expectedSettings)
        async let saveQuickPreferences: Void = repository.saveQuickSurfacePreferences(quickPreferences)
        _ = try await (saveSettings, saveQuickPreferences)

        let snapshot = try await repository.ledgerSnapshot()

        XCTAssertEqual(snapshot.settings, expectedSettings)
        XCTAssertEqual(snapshot.settingsMetadata.quickSurfacePreferences, quickPreferences)
    }

    private func makeRepository() -> CoreDataLedgerRepository {
        CoreDataLedgerRepository(
            persistence: PersistenceController(inMemory: true, cloudSyncEnabled: false)
        )
    }

    private func setRawQuickSurfaceState(
        persistence: PersistenceController,
        timerVisible: Bool,
        widgetPrivacyMode: String?
    ) throws {
        try persistence.container.viewContext.performAndWait {
            let request: NSFetchRequest<SettingsEntity> = SettingsEntity.request()
            let objects = try persistence.container.viewContext.fetch(request)
            let object = try XCTUnwrap(objects.first)
            object.timerVisible = timerVisible
            object.widgetPrivacyMode = widgetPrivacyMode
            try persistence.container.viewContext.save()
        }
    }

    private func setReservedMetadata(
        persistence: PersistenceController,
        syncMode: String,
        lastPurgeAt: Date
    ) throws {
        try persistence.container.viewContext.performAndWait {
            let request: NSFetchRequest<SettingsEntity> = SettingsEntity.request()
            let objects = try persistence.container.viewContext.fetch(request)
            let object = try XCTUnwrap(objects.first)
            object.syncMode = syncMode
            object.lastPurgeAt = lastPurgeAt
            try persistence.container.viewContext.save()
        }
    }
}
