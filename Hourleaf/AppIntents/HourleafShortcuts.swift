import AppIntents

struct HourleafShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .grayGreen }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RecordServiceTimeIntent(),
            phrases: [
                "Record service time in \(.applicationName)",
                "\(.applicationName), record service time"
            ],
            shortTitle: "intent.shortcut.add_service",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: RecordCreditTimeIntent(),
            phrases: [
                "Record credit time in \(.applicationName)",
                "\(.applicationName), record credit time"
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
