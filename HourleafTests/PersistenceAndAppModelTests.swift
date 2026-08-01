import CoreData
import XCTest
@testable import Hourleaf

@MainActor
final class PersistenceAndAppModelTests: XCTestCase {
    func testRepositoryRoundTripsEntrySettingsPolicyReminderAndReceipt() throws {
        let repository = makeRepository()
        let entry = TimeEntry(
            kind: .service,
            day: LocalDay(year: 2026, month: 7, day: 12),
            minutes: 75,
            note: "Morning"
        )
        try repository.saveEntry(entry)
        XCTAssertEqual(try repository.fetchEntries(), [entry])

        var settings = try repository.loadSettings()
        settings.onboardingComplete = true
        settings.reportLanguage = .ukrainian
        try repository.saveSettings(settings)
        XCTAssertEqual(try repository.loadSettings().reportLanguage, .ukrainian)

        let policy = ReportingPolicy(effectiveMonth: MonthKey(year: 2026, month: 7), mode: .discard)
        try repository.savePolicy(policy)
        XCTAssertEqual(try repository.fetchPolicies().first?.mode, .discard)

        let reminder = ReminderSchedule(weekday: 2, hour: 13, minute: 30)
        try repository.saveReminder(reminder)
        XCTAssertEqual(try repository.fetchReminders(), [reminder])

        let receipt = ReportReceipt(
            id: UUID(),
            month: MonthKey(year: 2026, month: 7),
            text: "July 2026\nHours: 1",
            serviceHours: 1,
            creditHours: 0,
            serviceCarryOut: 15,
            creditCarryOut: 0,
            preparedAt: .now,
            confirmedSentAt: .now
        )
        try repository.saveReceipt(receipt)
        XCTAssertEqual(try repository.fetchReceipts().first?.id, receipt.id)

        try repository.deleteEntry(id: entry.id)
        XCTAssertTrue(try repository.fetchEntries().isEmpty)
    }

    func testPastEditMarksConfirmedReceiptStale() throws {
        let repository = makeRepository()
        let model = AppModel(repository: repository, reminderScheduler: TestReminderScheduler())
        let month = MonthKey(Date(), calendar: .hourleaf)
        let date = LocalDay(year: month.year, month: month.month, day: 10).date(calendar: .hourleaf)
        XCTAssertTrue(model.addEntry(kind: .service, date: date, hours: 1, minutes: 15, note: nil))

        let report = model.report(for: month)
        let text = ReportFormatter.format(report, settings: model.settings)
        let receipt = try XCTUnwrap(model.createReceipt(for: report, text: text))
        model.markReceiptSent(receipt)
        let entry = try XCTUnwrap(model.entries.first)

        XCTAssertTrue(model.updateEntry(entry, kind: .service, date: date, hours: 2, minutes: 0, note: nil))
        let storedReceipt = try XCTUnwrap(model.receipts.first)
        XCTAssertTrue(model.isStale(storedReceipt))
        XCTAssertTrue(model.changeAffectsConfirmedReport(from: month))
    }

    func testAddCommandRejectsZeroDuration() throws {
        let repository = makeRepository()
        XCTAssertThrowsError(
            try AddTimeEntryCommand(repository: repository)
                .execute(kind: .service, date: .now, hours: 0, minutes: 0, note: nil)
        ) { error in
            XCTAssertEqual(error as? EntryValidationError, .emptyDuration)
        }
    }

    func testOpeningBalanceOnlyAppliesToItsServiceYear() {
        let repository = makeRepository()
        let model = AppModel(repository: repository, reminderScheduler: TestReminderScheduler())
        let currentDay = LocalDay(Date(), calendar: .hourleaf)
        let currentStart = ServiceYearCalculator.serviceYearStart(containing: currentDay)
        var settings = model.settings
        settings.baselineServiceYearMinutes = 120
        settings.baselineServiceYearStart = currentStart.monthKey
        model.saveSettings(settings)

        XCTAssertEqual(model.serviceYearProgress(containing: currentDay), 120)
        XCTAssertEqual(
            model.serviceYearProgress(containing: LocalDay(year: currentStart.year + 1, month: 9, day: 1)),
            0
        )
    }

    func testSettingsImportPrefersConfiguredRecordAndRemovesDuplicate() throws {
        let persistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        let context = persistence.container.viewContext
        let localDefault: SettingsEntity = context.insert(SettingsEntity.self)
        localDefault.id = UUID()
        localDefault.reportLanguage = ReportLanguage.english.rawValue
        localDefault.onboardingComplete = false
        localDefault.updatedAt = .now
        let imported: SettingsEntity = context.insert(SettingsEntity.self)
        imported.id = UUID()
        imported.reportLanguage = ReportLanguage.russian.rawValue
        imported.onboardingComplete = true
        imported.updatedAt = .distantPast
        try context.save()

        let repository = CoreDataLedgerRepository(context: context)
        let loaded = try repository.loadSettings()
        let request: NSFetchRequest<SettingsEntity> = SettingsEntity.request()

        XCTAssertTrue(loaded.onboardingComplete)
        XCTAssertEqual(loaded.reportLanguage, .russian)
        XCTAssertEqual(try context.count(for: request), 1)
    }

    private func makeRepository() -> CoreDataLedgerRepository {
        let persistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        return CoreDataLedgerRepository(context: persistence.container.viewContext)
    }
}

@MainActor
private final class TestReminderScheduler: ReminderScheduling {
    func requestAuthorization() async throws -> Bool { true }
    func reschedule(_ reminders: [ReminderSchedule]) async throws {}
}
