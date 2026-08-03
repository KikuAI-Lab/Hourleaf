import AppIntents

struct OpenQuickEntryIntent: AppIntent {
    static var title: LocalizedStringResource {
        "intent.open_quick_entry.title"
    }

    static var description: IntentDescription {
        IntentDescription("intent.open_quick_entry.description")
    }

    static var openAppWhenRun: Bool { true }
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    @AppDependency private var router: AppRouter

    init() {
        _router = AppDependency()
    }

    init(dependencyManager: AppDependencyManager) {
        _router = AppDependency(manager: dependencyManager)
    }

    static var parameterSummary: some ParameterSummary {
        Summary("intent.open_quick_entry.summary")
    }

    func perform() async throws -> some IntentResult {
        await route(using: router)
        return .result()
    }

    /// Allows a test to verify routing without touching AppIntent's framework
    /// execution context. The production path above still obtains the router
    /// from `@AppDependency`.
    func route(using router: AppRouter) async {
        await router.route(to: .quickEntry)
    }
}
