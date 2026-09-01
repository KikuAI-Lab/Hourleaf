import XCTest
@testable import Hourleaf

@MainActor
final class ReportAppModelTests: XCTestCase {
    func testDraftPreviewIgnoresLegacyCurrentMonthSnapshotText() {
        XCTAssertEqual(
            ReportPreviewText.resolve(
                draftText: "Live current-month draft",
                lifecycleState: .draft,
                snapshotText: "Stale immutable snapshot"
            ),
            "Live current-month draft"
        )
        XCTAssertEqual(
            ReportPreviewText.resolve(
                draftText: "Live closed-month draft",
                lifecycleState: .prepared,
                snapshotText: "Prepared immutable snapshot"
            ),
            "Prepared immutable snapshot"
        )
    }

    func testInitialLoadReconcilesZeroEntryPreviousMonthFromOneInstant() async throws {
        let now = testDate(year: 2026, month: 10, day: 2)
        let base = makeRepository(now: now)
        try await configureLedger(base, starting: MonthKey(year: 2026, month: 9))
        let repository = ReportAppModelGatedRepository(base: base)
        let model = AppModel(
            repository: repository,
            reminderScheduler: ReportAppModelReminderScheduler(),
            now: { now }
        )

        await model.loadInitialSnapshot()

        let previousMonth = MonthKey(year: 2026, month: 9)
        let reconciliationInstants = await repository.reconciliationInstants()
        XCTAssertEqual(reconciliationInstants, [now])
        XCTAssertEqual(model.currentDate, now)
        XCTAssertEqual(model.currentMonth, MonthKey(year: 2026, month: 10))
        XCTAssertEqual(model.selectedReportMonth, previousMonth)
        XCTAssertEqual(model.lifecycleState(for: previousMonth), .ready)
        XCTAssertTrue(model.reportDraft(for: previousMonth).entries.isEmpty)
        XCTAssertEqual(model.reportStates.first(where: { $0.month == previousMonth })?.state, .ready)
    }

    func testReviewBusyKeyRejectsDuplicateAndAppliesRepositoryLedger() async throws {
        let now = testDate(year: 2026, month: 10, day: 2)
        let base = makeRepository(now: now)
        try await configureLedger(base, starting: MonthKey(year: 2026, month: 9))
        let repository = ReportAppModelGatedRepository(base: base)
        await repository.setReviewGateEnabled(true)
        let model = AppModel(
            repository: repository,
            reminderScheduler: ReportAppModelReminderScheduler(),
            now: { now }
        )
        await model.loadInitialSnapshot()
        let draft = model.reportDraft(for: MonthKey(year: 2026, month: 9))

        let firstReview = Task { await model.reviewReport(draft) }
        while await repository.reviewRequestCount() == 0 {
            await Task.yield()
        }

        XCTAssertTrue(model.reviewingReportMonths.contains(draft.month))
        let duplicateReviewSucceeded = await model.reviewReport(draft)
        let reviewRequestCount = await repository.reviewRequestCount()
        XCTAssertFalse(duplicateReviewSucceeded)
        XCTAssertEqual(reviewRequestCount, 1)

        await repository.releaseReview()
        let firstReviewSucceeded = await firstReview.value
        let storedLedger = try await base.ledgerSnapshot()
        XCTAssertTrue(firstReviewSucceeded)
        XCTAssertTrue(model.reviewingReportMonths.isEmpty)
        XCTAssertEqual(model.lifecycleState(for: draft.month), .reviewed)
        XCTAssertEqual(model.reportStates, storedLedger.reportStates)
    }

    func testPrepareReplayReturnsStoredSnapshotAndMarkSentIsExplicit() async throws {
        let now = testDate(year: 2026, month: 10, day: 2)
        let base = makeRepository(now: now)
        try await configureLedger(base, starting: MonthKey(year: 2026, month: 9))
        let repository = ReportAppModelGatedRepository(base: base)
        await repository.setPrepareReplayEnabled(true)
        let model = AppModel(
            repository: repository,
            reminderScheduler: ReportAppModelReminderScheduler(),
            now: { now }
        )
        await model.loadInitialSnapshot()
        let draft = model.reportDraft(for: MonthKey(year: 2026, month: 9))
        let reviewed = await model.reviewReport(draft)
        XCTAssertTrue(reviewed)

        let preparedResult = await model.prepareReport(draft)
        let prepared = try XCTUnwrap(preparedResult)
        let prepareRequestCount = await repository.prepareRequestCount()

        XCTAssertEqual(prepareRequestCount, 1)
        XCTAssertEqual(prepared.receipt.text, draft.text)
        XCTAssertNil(prepared.receipt.confirmedSentAt)
        XCTAssertEqual(model.lifecycleState(for: draft.month), .prepared)
        XCTAssertEqual(model.reportSnapshots.count, 1)

        let markedSent = await model.markReportSent(prepared)
        let markSentRequestCount = await repository.markSentRequestCount()
        let storedLedger = try await base.ledgerSnapshot()
        XCTAssertTrue(markedSent)
        XCTAssertEqual(markSentRequestCount, 1)
        XCTAssertEqual(model.lifecycleState(for: draft.month), .sent)
        XCTAssertEqual(model.reportSnapshots.first?.receipt.confirmedSentAt, now)
        XCTAssertEqual(model.reportSnapshots, storedLedger.reportSnapshots)
    }

    func testSendImmediatelySkipsReviewScreenAndPersistsSentSnapshot() async throws {
        let now = testDate(year: 2026, month: 10, day: 2)
        let base = makeRepository(now: now)
        try await configureLedger(base, starting: MonthKey(year: 2026, month: 9))
        let repository = ReportAppModelGatedRepository(base: base)
        let model = AppModel(
            repository: repository,
            reminderScheduler: ReportAppModelReminderScheduler(),
            now: { now }
        )
        await model.loadInitialSnapshot()
        let month = MonthKey(year: 2026, month: 9)
        let draft = model.reportDraft(for: month)

        let sentResult = await model.sendReportImmediately(draft)
        let sent = try XCTUnwrap(sentResult)
        let storedLedger = try await base.ledgerSnapshot()
        let reviewRequestCount = await repository.reviewRequestCount()
        let prepareRequestCount = await repository.prepareRequestCount()
        let markSentRequestCount = await repository.markSentRequestCount()

        XCTAssertEqual(reviewRequestCount, 1)
        XCTAssertEqual(prepareRequestCount, 1)
        XCTAssertEqual(markSentRequestCount, 1)
        XCTAssertEqual(sent.receipt.confirmedSentAt, now)
        XCTAssertEqual(model.lifecycleState(for: month), .sent)
        XCTAssertEqual(model.reportSnapshots, storedLedger.reportSnapshots)
    }

    func testFingerprintMismatchRefreshesLedgerAndShowsLocalizedChangedError() async throws {
        let now = testDate(year: 2026, month: 10, day: 2)
        let repository = makeRepository(now: now)
        try await configureLedger(repository, starting: MonthKey(year: 2026, month: 9))
        let model = AppModel(
            repository: repository,
            reminderScheduler: ReportAppModelReminderScheduler(),
            now: { now }
        )
        await model.loadInitialSnapshot()
        let staleDraft = model.reportDraft(for: MonthKey(year: 2026, month: 9))

        var changedSettings = try await repository.loadSettings()
        changedSettings.reportLanguage = .russian
        try await repository.saveSettings(changedSettings)

        let reviewed = await model.reviewReport(staleDraft)
        XCTAssertFalse(reviewed)
        XCTAssertEqual(model.settings.reportLanguage, .russian)
        XCTAssertEqual(model.lifecycleState(for: staleDraft.month), .ready)
        XCTAssertEqual(model.errorMessage, String(localized: "error.report_changed"))
    }

    func testCloseServiceYearPublishesImmutableServiceOnlyArchive() async throws {
        let now = testDate(year: 2026, month: 10, day: 2)
        let repository = makeRepository(now: now)
        let start = MonthKey(year: 2024, month: 9)
        var settings = try await repository.loadSettings()
        settings.ledgerStartMonth = start
        settings.baselineServiceYearStart = start
        settings.baselineServiceYearMinutes = 60
        try await repository.saveSettings(settings)
        _ = try await AddTimeEntryCommand(repository: repository).execute(
            kind: .service,
            date: testDate(year: 2025, month: 3, day: 10),
            hours: 2,
            minutes: 0,
            note: nil
        )
        _ = try await AddTimeEntryCommand(repository: repository).execute(
            kind: .credit,
            date: testDate(year: 2025, month: 3, day: 11),
            hours: 3,
            minutes: 0,
            note: nil
        )
        let model = AppModel(
            repository: repository,
            reminderScheduler: ReportAppModelReminderScheduler(),
            now: { now }
        )
        await model.loadInitialSnapshot()

        let draft = model.serviceYearDraft(starting: start)
        let archiveResult = await model.closeServiceYear(draft)
        let archive = try XCTUnwrap(archiveResult)
        let storedLedger = try await repository.ledgerSnapshot()

        XCTAssertEqual(archive.actualServiceMinutes, 120)
        XCTAssertEqual(archive.baselineServiceMinutes, 60)
        XCTAssertEqual(archive.targetMinutes, GoalPolicy.regularPioneer.targetMinutes)
        XCTAssertEqual(model.serviceYearArchives, [archive])
        XCTAssertEqual(model.serviceYearArchives, storedLedger.serviceYearArchives)
    }

    private func makeRepository(now: Date) -> CoreDataLedgerRepository {
        let persistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        return CoreDataLedgerRepository(persistence: persistence, clock: { now })
    }

    private func configureLedger(
        _ repository: CoreDataLedgerRepository,
        starting month: MonthKey
    ) async throws {
        var settings = try await repository.loadSettings()
        settings.ledgerStartMonth = month
        settings.reportLanguage = .english
        try await repository.saveSettings(settings)
    }

    private func testDate(year: Int, month: Int, day: Int) -> Date {
        var calendar = Calendar.hourleaf
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: 12)
        )!
    }
}

private actor ReportAppModelGatedRepository: LedgerRepository {
    private let base: CoreDataLedgerRepository
    private var reconcileDates: [Date] = []
    private var reviewRequests: [ReviewReportRequest] = []
    private var prepareRequests: [PrepareReportRequest] = []
    private var markSentRequests: [MarkReportSentRequest] = []
    private var reviewGateEnabled = false
    private var reviewRelease: CheckedContinuation<Void, Never>?
    private var prepareReplayEnabled = false

    init(base: CoreDataLedgerRepository) {
        self.base = base
    }

    func setReviewGateEnabled(_ enabled: Bool) {
        reviewGateEnabled = enabled
    }

    func setPrepareReplayEnabled(_ enabled: Bool) {
        prepareReplayEnabled = enabled
    }

    func reconciliationInstants() -> [Date] { reconcileDates }
    func reviewRequestCount() -> Int { reviewRequests.count }
    func prepareRequestCount() -> Int { prepareRequests.count }
    func markSentRequestCount() -> Int { markSentRequests.count }

    func releaseReview() {
        reviewGateEnabled = false
        reviewRelease?.resume()
        reviewRelease = nil
    }

    func ledgerSnapshot() async throws -> LedgerSnapshot { try await base.ledgerSnapshot() }
    func fetchEntries() async throws -> [TimeEntry] { try await base.fetchEntries() }
    func fetchAllEntries() async throws -> [LedgerEntryRecord] { try await base.fetchAllEntries() }
    func apply(_ command: EntryMutationCommand) async throws -> EntryMutationReceipt {
        try await base.apply(command)
    }
    func latestUndoCandidate(asOf date: Date) async throws -> EntryUndoCandidate? {
        try await base.latestUndoCandidate(asOf: date)
    }
    func loadSettings() async throws -> AppSettings { try await base.loadSettings() }
    func saveSettings(_ settings: AppSettings) async throws { try await base.saveSettings(settings) }
    func fetchPolicies() async throws -> [ReportingPolicy] { try await base.fetchPolicies() }
    func savePolicy(_ policy: ReportingPolicy) async throws { try await base.savePolicy(policy) }
    func fetchReminders() async throws -> [ReminderSchedule] { try await base.fetchReminders() }
    func saveReminder(_ reminder: ReminderSchedule) async throws { try await base.saveReminder(reminder) }
    func deleteReminder(id: UUID) async throws { try await base.deleteReminder(id: id) }
    func fetchReceipts() async throws -> [ReportReceipt] { try await base.fetchReceipts() }

    func reconcileReportLifecycle(asOf now: Date) async throws -> LedgerSnapshot {
        reconcileDates.append(now)
        return try await base.reconcileReportLifecycle(asOf: now)
    }

    func reviewReport(_ request: ReviewReportRequest) async throws -> LedgerSnapshot {
        reviewRequests.append(request)
        if reviewGateEnabled {
            await withCheckedContinuation { continuation in
                reviewRelease = continuation
            }
        }
        return try await base.reviewReport(request)
    }

    func prepareReport(_ request: PrepareReportRequest) async throws -> PreparedReportResult {
        prepareRequests.append(request)
        let first = try await base.prepareReport(request)
        guard prepareReplayEnabled else { return first }
        return try await base.prepareReport(request)
    }

    func markReportSent(_ request: MarkReportSentRequest) async throws -> LedgerSnapshot {
        markSentRequests.append(request)
        return try await base.markReportSent(request)
    }

    func closeServiceYear(_ request: CloseServiceYearRequest) async throws -> ServiceYearArchiveResult {
        try await base.closeServiceYear(request)
    }
}

@MainActor
private final class ReportAppModelReminderScheduler: ReminderScheduling {
    func requestAuthorization() async throws -> Bool { true }
    func reschedule(_ reminders: [ReminderSchedule]) async throws {}
}
