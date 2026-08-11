import SwiftUI

@main
struct HourleafWatchApp: App {
    init() {
        HourleafWatchShortcuts.updateAppShortcutParameters()
        Task { @MainActor in
            HourleafWatchConnectivityClient.shared.activate()
        }
    }

    var body: some Scene {
        WindowGroup {
            WatchEntryView()
        }
    }
}
