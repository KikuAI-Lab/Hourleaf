import CoreData
import XCTest
@testable import Hourleaf

@MainActor
final class PlanningPersistenceTests: XCTestCase {
    func testAppModelPlanningTogglePublishesPersistedReadback() async throws {
        let repository = CoreDataLedgerRepository(
            persistence: PersistenceController(inMemory: true, cloudSyncEnabled: false)
        )
        let model = AppModel(
            repository: repository,
            reminderScheduler: PlanningTestReminderScheduler()
        )
        await model.loadInitialSnapshot()

        XCTAssertFalse(model.planningPreferences.isPaceVisible)
        await model.updatePlanningVisibility(true)

        XCTAssertTrue(model.planningPreferences.isPaceVisible)
        let snapshot = try await repository.ledgerSnapshot()
        XCTAssertTrue(snapshot.settingsMetadata.planningVisible)
        XCTAssertNil(model.errorMessage)
    }

    func testPlanningPreferencesPreserveUnrelatedSettings() async throws {
        let repository = CoreDataLedgerRepository(
            persistence: PersistenceController(inMemory: true, cloudSyncEnabled: false)
        )
        var settings = try await repository.loadSettings()
        settings.reportLanguage = .ukrainian
        settings.creditLabelUkrainian = "Особливий кредит"
        settings.ledgerStartMonth = MonthKey(year: 2026, month: 1)
        settings.baselineServiceYearMinutes = 12_345
        settings.baselineServiceYearStart = MonthKey(year: 2025, month: 9)
        settings.openingServiceCarryMinutes = 23
        settings.openingCreditCarryMinutes = 45
        settings.onboardingComplete = true
        try await repository.saveSettings(settings)

        let preferences = PlanningPreferences(
            isPaceVisible: true,
            isQuietGapEnabled: true,
            quietGapDays: 7
        )
        try await repository.savePlanningPreferences(preferences)
        let snapshot = try await repository.ledgerSnapshot()

        XCTAssertEqual(snapshot.settings, settings)
        XCTAssertTrue(snapshot.settingsMetadata.planningVisible)
        XCTAssertTrue(snapshot.settingsMetadata.quietGapCheckEnabled)
        XCTAssertEqual(snapshot.settingsMetadata.quietGapDays, 7)
    }

    func testAcknowledgementUpsertsOneLogicalDayAndCreatesNoTime() async throws {
        let persistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        let repository = CoreDataLedgerRepository(persistence: persistence)
        try await setLedgerStart(MonthKey(year: 2026, month: 1), repository: repository)
        let before = try await repository.ledgerSnapshot()
        let instant = fixedDate(year: 2026, month: 3, day: 5, hour: 18)
        let target = LocalDay(instant, calendar: .hourleaf)

        let first = try await repository.acknowledgeNothingToRecord(
            on: target,
            source: .scheduledReminder,
            at: instant
        )
        let replay = try await repository.acknowledgeNothingToRecord(
            on: target,
            source: .scheduledReminder,
            at: instant
        )
        let snapshot = try await repository.ledgerSnapshot()

        XCTAssertEqual(replay.id, first.id)
        XCTAssertEqual(snapshot.dayAcknowledgements.count, 1)
        XCTAssertEqual(snapshot.dayAcknowledgements.first?.status, "nothingToday")
        XCTAssertEqual(snapshot.dayAcknowledgements.first?.source, "scheduledReminder")
        XCTAssertTrue(snapshot.entries.isEmpty)
        XCTAssertTrue(snapshot.entryRevisions.isEmpty)
        XCTAssertEqual(snapshot.reportSnapshots, before.reportSnapshots)
        XCTAssertEqual(snapshot.reportStates, before.reportStates)
        XCTAssertEqual(snapshot.serviceYearArchives, before.serviceYearArchives)
    }

    func testAcknowledgementRejectsFutureAndPreLedgerDays() async throws {
        let persistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        let repository = CoreDataLedgerRepository(persistence: persistence)
        try await setLedgerStart(MonthKey(year: 2026, month: 3), repository: repository)
        let instant = fixedDate(year: 2026, month: 3, day: 5, hour: 18)

        await XCTAssertThrowsErrorAsync {
            _ = try await repository.acknowledgeNothingToRecord(
                on: LocalDay(year: 2026, month: 3, day: 6),
                source: .scheduledReminder,
                at: instant
            )
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await repository.acknowledgeNothingToRecord(
                on: LocalDay(year: 2026, month: 2, day: 28),
                source: .quietGap,
                at: instant
            )
        }

        let rejectedSnapshot = try await repository.ledgerSnapshot()
        XCTAssertTrue(rejectedSnapshot.dayAcknowledgements.isEmpty)
    }

    func testDuplicateImportedAcknowledgementsFailClosedWithoutDeletingEither() async throws {
        let persistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        let repository = CoreDataLedgerRepository(persistence: persistence)
        try await setLedgerStart(MonthKey(year: 2026, month: 1), repository: repository)
        let instant = fixedDate(year: 2026, month: 3, day: 5, hour: 18)
        let target = LocalDay(instant, calendar: .hourleaf)

        try persistence.container.viewContext.performAndWait {
            for offset in 0...1 {
                let object = persistence.container.viewContext.insert(DayAcknowledgementEntity.self)
                object.id = UUID()
                object.localDay = target.key
                object.status = DayAcknowledgementStatus.nothingToday.rawValue
                object.source = DayAcknowledgementSource.scheduledReminder.rawValue
                object.createdAt = instant.addingTimeInterval(Double(offset))
                object.updatedAt = instant.addingTimeInterval(Double(offset))
            }
            try persistence.container.viewContext.save()
        }

        await XCTAssertThrowsErrorAsync {
            _ = try await repository.acknowledgeNothingToRecord(
                on: target,
                source: .quietGap,
                at: instant.addingTimeInterval(10)
            )
        }

        let duplicateSnapshot = try await repository.ledgerSnapshot()
        XCTAssertEqual(duplicateSnapshot.dayAcknowledgements.count, 2)
    }

    func testPlanningAndAcknowledgementSurviveRepositoryRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HourleafPlanningRestart-\(UUID().uuidString)", isDirectory: true)
        let storeURL = directory.appendingPathComponent("Hourleaf.sqlite")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var firstPersistence: PersistenceController? = PersistenceController(
            inMemory: false,
            cloudSyncEnabled: false,
            storeURL: storeURL
        )
        var firstRepository: CoreDataLedgerRepository? = CoreDataLedgerRepository(
            persistence: try XCTUnwrap(firstPersistence)
        )
        try await setLedgerStart(
            MonthKey(year: 2026, month: 1),
            repository: try XCTUnwrap(firstRepository)
        )
        try await firstRepository?.savePlanningPreferences(
            PlanningPreferences(isPaceVisible: true, isQuietGapEnabled: true, quietGapDays: 7)
        )
        let instant = fixedDate(year: 2026, month: 3, day: 5, hour: 18)
        _ = try await firstRepository?.acknowledgeNothingToRecord(
            on: LocalDay(instant, calendar: .hourleaf),
            source: .quietGap,
            at: instant
        )
        try close(try XCTUnwrap(firstPersistence))
        firstRepository = nil
        firstPersistence = nil

        let reopened = PersistenceController(
            inMemory: false,
            cloudSyncEnabled: false,
            storeURL: storeURL
        )
        defer { try? close(reopened) }
        let snapshot = try await CoreDataLedgerRepository(persistence: reopened).ledgerSnapshot()

        XCTAssertTrue(snapshot.settingsMetadata.planningVisible)
        XCTAssertTrue(snapshot.settingsMetadata.quietGapCheckEnabled)
        XCTAssertEqual(snapshot.settingsMetadata.quietGapDays, 7)
        XCTAssertEqual(snapshot.dayAcknowledgements.count, 1)
        XCTAssertEqual(snapshot.dayAcknowledgements.first?.source, "quietGap")
    }

    private func setLedgerStart(
        _ month: MonthKey,
        repository: CoreDataLedgerRepository
    ) async throws {
        var settings = try await repository.loadSettings()
        settings.ledgerStartMonth = month
        try await repository.saveSettings(settings)
    }

    private func fixedDate(year: Int, month: Int, day: Int, hour: Int) -> Date {
        Calendar.hourleaf.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour)
        )!
    }

    private func close(_ persistence: PersistenceController) throws {
        let coordinator = persistence.container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            try coordinator.remove(store)
        }
    }
}

@MainActor
private final class PlanningTestReminderScheduler: ReminderScheduling {
    func requestAuthorization() async throws -> Bool { true }
    func reschedule(_ reminders: [ReminderSchedule]) async throws {}
}

@MainActor
private func XCTAssertThrowsErrorAsync(
    _ expression: @MainActor () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error to be thrown.", file: file, line: line)
    } catch {
        // Expected.
    }
}
