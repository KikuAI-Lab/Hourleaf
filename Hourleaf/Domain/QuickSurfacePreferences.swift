import Foundation

enum WidgetPrivacyMode: String, CaseIterable, Sendable {
    case hideTotals
    case showTotals

    init(persistedValue: String?) {
        self = Self(rawValue: persistedValue ?? "") ?? .hideTotals
    }
}

struct QuickSurfacePreferences: Equatable, Sendable {
    var timerVisible = false
    var privacyMode: WidgetPrivacyMode = .hideTotals
}

extension LedgerSettingsMetadata {
    var quickSurfacePreferences: QuickSurfacePreferences {
        QuickSurfacePreferences(
            timerVisible: timerVisible,
            privacyMode: WidgetPrivacyMode(persistedValue: widgetPrivacyMode)
        )
    }
}
