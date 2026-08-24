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

struct QuickSurfaceIntentProjectionRefresher: Sendable {
    private let operation: @Sendable () async -> Void

    static let disabled = QuickSurfaceIntentProjectionRefresher(operation: {})

    init(
        repository: CoreDataLedgerRepository,
        quickSurfaceHost: QuickSurfaceHostController,
        systemReloader: QuickSurfaceSystemReloader = .disabled
    ) {
        operation = {
            guard quickSurfaceHost.capabilityExpected,
                  let snapshot = try? await repository.ledgerSnapshot()
            else { return }
            _ = await quickSurfaceHost.reconcile(snapshot)
            systemReloader.reload()
        }
    }

    private init(operation: @escaping @Sendable () async -> Void) {
        self.operation = operation
    }

    func refreshAfterMutation() async {
        await operation()
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
        let quickSurfaceRefresher: QuickSurfaceIntentProjectionRefresher

        func resolveRepository() -> CoreDataLedgerRepository {
            repository
        }

        @MainActor
        func resolveRouter() -> AppRouter {
            router
        }

        func resolveQuickSurfaceRefresher() -> QuickSurfaceIntentProjectionRefresher {
            quickSurfaceRefresher
        }
    }

    @discardableResult
    static func register(
        repository: CoreDataLedgerRepository,
        router: AppRouter,
        quickSurfaceRefresher: QuickSurfaceIntentProjectionRefresher = .disabled,
        manager: AppDependencyManager = .shared
    ) -> Registration {
        let registration = Registration(
            repository: repository,
            router: router,
            quickSurfaceRefresher: quickSurfaceRefresher
        )
        manager.add(dependency: registration.repository)
        manager.add(dependency: registration.router)
        manager.add(dependency: registration.quickSurfaceRefresher)
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
        // Recording adds a validated entry but never reveals ledger contents.
        // Allowing background execution keeps Siri and Shortcuts usable from
        // the lock screen while Core Data still enforces the normal command
        // validation and file-protection boundaries.
        .alwaysAllowed
    }

    @Parameter(title: "intent.record.kind", default: .service)
    var kind: ShortcutEntryKind

    /// A single duration parameter lets Siri understand an answer such as
    /// “one hour twenty minutes” without presenting separate number pickers.
    @Parameter(
        title: "intent.record.duration",
        defaultUnit: .minutes,
        supportsNegativeNumbers: false,
        requestValueDialog: "intent.record.duration_prompt"
    )
    var duration: Measurement<UnitDuration>

    @Parameter(title: "intent.record.date", kind: .date)
    var date: Date?

    @AppDependency private var repository: CoreDataLedgerRepository
    @AppDependency private var router: AppRouter
    @AppDependency private var quickSurfaceRefresher: QuickSurfaceIntentProjectionRefresher

    init() {
        _repository = AppDependency()
        _router = AppDependency()
        _quickSurfaceRefresher = AppDependency()
    }

    init(
        kind: ShortcutEntryKind,
        hours: Int? = nil,
        minutes: Int? = nil,
        duration: Measurement<UnitDuration>? = nil,
        date: Date? = nil,
        dependencyManager: AppDependencyManager = .shared
    ) {
        self.kind = kind
        if let duration {
            self.duration = duration
        } else if hours != nil || minutes != nil {
            self.duration = Measurement(
                value: Double((hours ?? 0) * 60 + (minutes ?? 0)),
                unit: .minutes
            )
        }
        self.date = date
        _repository = AppDependency(manager: dependencyManager)
        _router = AppDependency(manager: dependencyManager)
        _quickSurfaceRefresher = AppDependency(manager: dependencyManager)
    }

    static var parameterSummary: some ParameterSummary {
        Summary("intent.record.summary") {
            \.$kind
            \.$duration
            \.$date
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await persist(
            using: repository,
            notifying: router,
            refreshing: quickSurfaceRefresher
        )
        return .result(dialog: IntentDialog("intent.record.success"))
    }

    /// Isolates the durable write for tests without granting them another
    /// repository construction path. System execution still resolves through
    /// `@AppDependency` in `perform()` above.
    func persist(
        using repository: CoreDataLedgerRepository,
        notifying router: AppRouter? = nil,
        refreshing quickSurfaceRefresher: QuickSurfaceIntentProjectionRefresher? = nil
    ) async throws {
        let now = Date.now
        let mutationID = UUID()
        let entryID = UUID()

        do {
            let totalMinutes: Int
            do {
                totalMinutes = try WatchTimeEntryDurationV1.totalMinutes(duration: duration)
            } catch WatchTimeEntryContractError.emptyDuration {
                throw EntryValidationError.emptyDuration
            } catch WatchTimeEntryContractError.durationTooLarge {
                throw EntryValidationError.durationTooLarge
            } catch {
                throw EntryValidationError.invalidMinutes
            }

            _ = try await AddTimeEntryCommand(repository: repository).execute(
                kind: kind.entryKind,
                date: date ?? now,
                hours: totalMinutes / 60,
                minutes: totalMinutes % 60,
                note: nil,
                mutationID: mutationID,
                entryID: entryID,
                occurredAt: now,
                source: .shortcut
            )
            await quickSurfaceRefresher?.refreshAfterMutation()
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

/// A fixed-kind action for user shortcuts named “Запиши кредит”.
///
/// A custom shortcut stores the action itself, not the preconfigured value
/// passed by `AppShortcut`. Keeping credit as a distinct intent prevents that
/// value from silently falling back to service after sync to Apple Watch.
struct RecordCreditTimeIntent: AppIntent {
    static var title: LocalizedStringResource {
        "intent.shortcut.add_credit"
    }

    static var description: IntentDescription {
        IntentDescription("intent.record.description")
    }

    static var openAppWhenRun: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy {
        .alwaysAllowed
    }

    @Parameter(
        title: "intent.record.duration",
        defaultUnit: .minutes,
        supportsNegativeNumbers: false,
        requestValueDialog: "intent.record.duration_prompt"
    )
    var duration: Measurement<UnitDuration>

    @Parameter(title: "intent.record.date", kind: .date)
    var date: Date?

    @AppDependency private var repository: CoreDataLedgerRepository
    @AppDependency private var router: AppRouter
    @AppDependency private var quickSurfaceRefresher: QuickSurfaceIntentProjectionRefresher

    init() {
        _repository = AppDependency()
        _router = AppDependency()
        _quickSurfaceRefresher = AppDependency()
    }

    init(
        duration: Measurement<UnitDuration>? = nil,
        date: Date? = nil,
        dependencyManager: AppDependencyManager = .shared
    ) {
        if let duration {
            self.duration = duration
        }
        self.date = date
        _repository = AppDependency(manager: dependencyManager)
        _router = AppDependency(manager: dependencyManager)
        _quickSurfaceRefresher = AppDependency(manager: dependencyManager)
    }

    static var parameterSummary: some ParameterSummary {
        Summary("intent.record.summary") {
            \.$duration
            \.$date
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await persist(
            using: repository,
            notifying: router,
            refreshing: quickSurfaceRefresher
        )
        return .result(dialog: IntentDialog("intent.record.success"))
    }

    func persist(
        using repository: CoreDataLedgerRepository,
        notifying router: AppRouter? = nil,
        refreshing quickSurfaceRefresher: QuickSurfaceIntentProjectionRefresher? = nil
    ) async throws {
        let intent = RecordTimeIntent(
            kind: .credit,
            duration: duration,
            date: date
        )
        try await intent.persist(
            using: repository,
            notifying: router,
            refreshing: quickSurfaceRefresher
        )
    }
}
