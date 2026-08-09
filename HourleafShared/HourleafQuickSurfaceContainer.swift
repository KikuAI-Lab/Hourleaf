import Foundation

/// The Info.plist key shared by the host app and the quick-surface extension.
///
/// Keeping this key in the shared Foundation-only boundary prevents either
/// process from having to duplicate an identifier or a container path.
enum HourleafAppGroupIdentifier {
    static let infoKey = "HourleafAppGroupIdentifier"
}

enum HourleafQuickSurfaceContainerUnavailableReason: Equatable, Sendable {
    case missingIdentifier
    case invalidIdentifier
    case unavailable
}

enum HourleafQuickSurfaceContainerResolution: Equatable, Sendable {
    case available(URL)
    case unavailable(HourleafQuickSurfaceContainerUnavailableReason)
}

/// Resolves the configured App Group without exposing its identifier or path
/// through an error value. The closure seam keeps unit tests independent from
/// signing and entitlement state.
struct HourleafQuickSurfaceContainer {
    static func resolve(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        containerURL: ((String) -> URL?)? = nil
    ) -> HourleafQuickSurfaceContainerResolution {
        guard let rawIdentifier = bundle.object(forInfoDictionaryKey: HourleafAppGroupIdentifier.infoKey) else {
            return .unavailable(.missingIdentifier)
        }
        guard let identifier = rawIdentifier as? String else {
            return .unavailable(.invalidIdentifier)
        }
        let trimmedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIdentifier.isEmpty else {
            return .unavailable(.invalidIdentifier)
        }

        let resolveContainer = containerURL ?? { value in
            fileManager.containerURL(forSecurityApplicationGroupIdentifier: value)
        }
        guard let url = resolveContainer(trimmedIdentifier), url.isFileURL else {
            return .unavailable(.unavailable)
        }
        return .available(url)
    }
}
