import AppIntents
import Foundation

enum PrepareMonthlyReportIntentError: LocalizedError, Equatable, Sendable {
    case noDraft
    case changed
    case unavailable

    var errorDescription: String? {
        switch self {
        case .noDraft:
            String(localized: "intent.report.no_draft")
        case .changed:
            String(localized: "intent.report.changed")
        case .unavailable:
            String(localized: "intent.report.unavailable")
        }
    }
}

struct PrepareMonthlyReportIntent: AppIntent {
    static var title: LocalizedStringResource {
        "intent.shortcut.prepare_report"
    }

    static var description: IntentDescription {
        IntentDescription("intent.report.description")
    }

    static var openAppWhenRun: Bool { false }
    static var isDiscoverable: Bool { true }
    static var authenticationPolicy: IntentAuthenticationPolicy {
        .requiresLocalDeviceAuthentication
    }

    @Parameter(title: "intent.report.month", kind: .date)
    var month: Date?

    @AppDependency private var repository: CoreDataLedgerRepository

    init() {
        _repository = AppDependency()
    }

    init(
        month: Date? = nil,
        dependencyManager: AppDependencyManager = .shared
    ) {
        self.month = month
        _repository = AppDependency(manager: dependencyManager)
    }

    static var parameterSummary: some ParameterSummary {
        Summary("intent.report.summary") {
            \.$month
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = try await prepare(using: repository, now: .now)
        return .result(value: text, dialog: IntentDialog("intent.report.success"))
    }

    /// Reads the existing report projection twice around formatting. The
    /// equality check proves this read-only action did not cross a mutation
    /// boundary while it prepared the text.
    func prepare(
        using repository: CoreDataLedgerRepository,
        now: Date
    ) async throws -> String {
        let before: LedgerSnapshot
        do {
            before = try await repository.ledgerSnapshot()
        } catch {
            throw PrepareMonthlyReportIntentError.unavailable
        }

        let requestedMonth = MonthKey(month ?? now, calendar: .hourleaf)
        let draft = ReportReadiness.draft(for: requestedMonth, in: before)

        let after: LedgerSnapshot
        do {
            after = try await repository.ledgerSnapshot()
        } catch {
            throw PrepareMonthlyReportIntentError.unavailable
        }
        guard before == after else {
            throw PrepareMonthlyReportIntentError.changed
        }

        guard let draft else {
            throw PrepareMonthlyReportIntentError.noDraft
        }

        return draft.text
    }
}
