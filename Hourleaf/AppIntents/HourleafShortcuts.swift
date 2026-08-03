import AppIntents

struct HourleafShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .grayGreen }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RecordTimeIntent(kind: .service),
            phrases: [
                "Add service time in \(.applicationName)",
                "Record service time in \(.applicationName)"
            ],
            shortTitle: "intent.shortcut.add_service",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: RecordTimeIntent(kind: .credit),
            phrases: [
                "Add credit time in \(.applicationName)",
                "Record credit time in \(.applicationName)"
            ],
            shortTitle: "intent.shortcut.add_credit",
            systemImageName: "plus.circle.fill"
        )
        AppShortcut(
            intent: OpenQuickEntryIntent(),
            phrases: [
                "Open Add Time in \(.applicationName)",
                "Open time entry in \(.applicationName)"
            ],
            shortTitle: "intent.shortcut.open_quick_entry",
            systemImageName: "square.and.pencil"
        )
    }
}
