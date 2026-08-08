import XCTest
@testable import Hourleaf

final class CSVImportCoordinatorTests: XCTestCase {
    private let authorizationTime = Date(timeIntervalSince1970: 1_786_179_600)

    func testConfirmUsesPreparedDocumentAndConsumesOnlyOnSuccess() async throws {
        let repository = makeRepository()
        let coordinator = CSVImportCoordinator(repository: repository)
        let directory = FileManager.default.temporaryDirectory
        let url = directory.appendingPathComponent("hourleaf-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(
            "date,kind,hours,minutes,total_minutes,note\n2026-08-07,service,0,30,30,Prepared\n".utf8
        ).write(to: url)

        let preview = try await coordinator.prepare(from: url)
        XCTAssertEqual(preview.totalRows, 1)
        try Data(
            "date,kind,hours,minutes,total_minutes,note\n2026-08-07,credit,0,45,45,Changed source\n".utf8
        ).write(to: url)

        let result = try await coordinator.confirm(
            preview.candidateID,
            policy: .skipPossibleMatches
        )
        XCTAssertEqual(result.importedCount, 1)
        let snapshot = try await repository.ledgerSnapshot()
        XCTAssertEqual(snapshot.activeEntries.first?.kind, .service)
        XCTAssertEqual(snapshot.activeEntries.first?.minutes, 30)
    }

    func testFailedConfirmKeepsCandidateForExplicitRetryAndDiscardRemovesIt() async throws {
        let repository = makeRepository()
        let coordinator = CSVImportCoordinator(repository: repository)
        let directory = FileManager.default.temporaryDirectory
        let url = directory.appendingPathComponent("hourleaf-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(
            "date,kind,hours,minutes,total_minutes,note\n2026-08-07,service,0,30,30,Retry\n".utf8
        ).write(to: url)

        let preview = try await coordinator.prepare(from: url)
        let invalidPolicyCandidate = UUID()
        do {
            _ = try await coordinator.confirm(
                invalidPolicyCandidate,
                policy: .skipPossibleMatches
            )
            XCTFail("A mismatched candidate must fail")
        } catch let error as CSVImportCoordinatorError {
            XCTAssertEqual(error, .noPreparedCandidate)
        }

        let result = try await coordinator.confirm(
            preview.candidateID,
            policy: .skipPossibleMatches
        )
        XCTAssertEqual(result.importedCount, 1)
        await coordinator.discard(preview.candidateID)
        do {
            _ = try await coordinator.confirm(
                preview.candidateID,
                policy: .skipPossibleMatches
            )
            XCTFail("Consumed candidates cannot be confirmed")
        } catch let error as CSVImportCoordinatorError {
            XCTAssertEqual(error, .noPreparedCandidate)
        }
    }

    func testMalformedPrepareDoesNotLeakSourceDetails() async throws {
        let repository = makeRepository()
        let coordinator = CSVImportCoordinator(repository: repository)
        let directory = FileManager.default.temporaryDirectory
        let url = directory.appendingPathComponent("private-note-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not,a,hourleaf,csv\nsecret note\n".utf8).write(to: url)

        do {
            _ = try await coordinator.prepare(from: url)
            XCTFail("Malformed CSV must fail")
        } catch {
            let message = error.localizedDescription
            XCTAssertFalse(message.contains(url.path))
            XCTAssertFalse(message.contains("secret note"))
        }
    }

    func testRepositoryFailureLeavesCandidateAvailableForExplicitRetry() async throws {
        let repository = makeRepository()
        let coordinator = CSVImportCoordinator(repository: repository)
        let directory = FileManager.default.temporaryDirectory
        let url = directory.appendingPathComponent("hourleaf-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(
            "date,kind,hours,minutes,total_minutes,note\n2026-08-07,service,0,30,30,Retry gate\n".utf8
        ).write(to: url)

        let preview = try await coordinator.prepare(from: url)
        var settings = try await repository.loadSettings()
        settings.ledgerStartMonth = MonthKey(year: 2026, month: 9)
        try await repository.saveSettings(settings)
        do {
            _ = try await coordinator.confirm(
                preview.candidateID,
                policy: .skipPossibleMatches
            )
            XCTFail("The repository gate should fail confirmation")
        } catch let error as CSVImportCoordinatorError {
            XCTAssertEqual(error, .importFailed)
        }

        settings.ledgerStartMonth = MonthKey(year: 2026, month: 8)
        try await repository.saveSettings(settings)
        let retry = try await coordinator.confirm(
            preview.candidateID,
            policy: .skipPossibleMatches
        )
        XCTAssertEqual(retry.importedCount, 1)
    }

    private func makeRepository() -> CoreDataLedgerRepository {
        let now = authorizationTime
        return CoreDataLedgerRepository(
            persistence: PersistenceController(inMemory: true, cloudSyncEnabled: false),
            clock: { now }
        )
    }
}
