import AppIntents
import Foundation

enum ShortcutEntryKind: String, AppEnum {
    case service
    case credit

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "intent.record.kind"
    }

    static var caseDisplayRepresentations: [ShortcutEntryKind: DisplayRepresentation] {
        [
            .service: "entry.kind.service",
            .credit: "entry.kind.credit"
        ]
    }

    var entryKind: EntryKind {
        switch self {
        case .service: .service
        case .credit: .credit
        }
    }
}

/// Registers the exact objects built by `HourleafApp` for production and an
/// isolated manager for tests. Neither dependency has a fallback factory.
enum HourleafAppIntentDependencies {
    /// Retains the exact live objects supplied by `HourleafApp` so tests can
    /// prove repeated resolution without ever constructing another repository.
    struct Registration: Sendable {
        let repository: CoreDataLedgerRepository
        let router: AppRouter

        func resolveRepository() -> CoreDataLedgerRepository {
            repository
        }

        @MainActor
        func resolveRouter() -> AppRouter {
            router
        }
    }

    @discardableResult
    static func register(
        repository: CoreDataLedgerRepository,
        router: AppRouter,
        manager: AppDependencyManager = .shared
    ) -> Registration {
        let registration = Registration(repository: repository, router: router)
        manager.add(dependency: registration.repository)
        manager.add(dependency: registration.router)
        return registration
    }
}

enum ShortcutIntentError: LocalizedError, Sendable {
    case saveFailed

    var errorDescription: String? {
        String(localized: "intent.record.save_failed")
    }
}

struct RecordTimeIntent: AppIntent {
    static var title: LocalizedStringResource {
        "intent.record.title"
    }

    static var description: IntentDescription {
        IntentDescription("intent.record.description")
    }

    static var openAppWhenRun: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy {
        .requiresLocalDeviceAuthentication
    }

    @Parameter(title: "intent.record.kind", default: .service)
    var kind: ShortcutEntryKind

    /// The promoted shortcuts deliberately leave both duration fields unset.
    /// Shortcuts therefore asks for them before `perform()` can write anything.
    @Parameter(
        title: "intent.record.hours",
        inclusiveRange: (0, 99),
        requestValueDialog: "intent.record.hours_prompt"
    )
    var hours: Int

    @Parameter(
        title: "intent.record.minutes",
        inclusiveRange: (0, 59),
        requestValueDialog: "intent.record.minutes_prompt"
    )
    var minutes: Int

    @Parameter(title: "intent.record.date", kind: .date)
    var date: Date?

    @AppDependency private var repository: CoreDataLedgerRepository
    @AppDependency private var router: AppRouter

    init() {
        _repository = AppDependency()
        _router = AppDependency()
    }

    init(
        kind: ShortcutEntryKind,
        hours: Int? = nil,
        minutes: Int? = nil,
        date: Date? = nil,
        dependencyManager: AppDependencyManager = .shared
    ) {
        self.kind = kind
        if let hours {
            self.hours = hours
        }
        if let minutes {
            self.minutes = minutes
        }
        self.date = date
        _repository = AppDependency(manager: dependencyManager)
        _router = AppDependency(manager: dependencyManager)
    }

    static var parameterSummary: some ParameterSummary {
        Summary("intent.record.summary") {
            \.$kind
            \.$hours
            \.$minutes
            \.$date
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await persist(using: repository, notifying: router)
        return .result(dialog: IntentDialog("intent.record.success"))
    }

    /// Isolates the durable write for tests without granting them another
    /// repository construction path. System execution still resolves through
    /// `@AppDependency` in `perform()` above.
    func persist(
        using repository: CoreDataLedgerRepository,
        notifying router: AppRouter? = nil
    ) async throws {
        let now = Date.now
        let mutationID = UUID()
        let entryID = UUID()

        do {
            _ = try await AddTimeEntryCommand(repository: repository).execute(
                kind: kind.entryKind,
                date: date ?? now,
                hours: hours,
                minutes: minutes,
                note: nil,
                mutationID: mutationID,
                entryID: entryID,
                occurredAt: now,
                source: .shortcut
            )
            if let router {
                await router.notifyLedgerChanged()
            }
        } catch let error as EntryValidationError {
            throw error
        } catch let error as EntryMutationError {
            throw error
        } catch {
            throw ShortcutIntentError.saveFailed
        }
    }
}
