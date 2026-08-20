import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    static let storageKey = "hourleaf.appearance"

    case system
    case light
    case dark

    var id: String { rawValue }

    init(storedValue: String) {
        self = Self(rawValue: storedValue) ?? .system
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var localizedName: LocalizedStringKey {
        switch self {
        case .system: "settings.appearance.system"
        case .light: "settings.appearance.light"
        case .dark: "settings.appearance.dark"
        }
    }
}
