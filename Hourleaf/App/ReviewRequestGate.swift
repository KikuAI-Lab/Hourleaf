import Foundation

@MainActor
enum ReviewRequestGate {
    static let lastRequestedVersionKey = "hourleaf.review.lastRequestedVersion"

    @discardableResult
    static func requestIfEligible(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        request: () -> Void
    ) -> Bool {
        requestIfEligible(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            defaults: defaults,
            request: request
        )
    }

    @discardableResult
    static func requestIfEligible(
        version: String?,
        defaults: UserDefaults = .standard,
        request: () -> Void
    ) -> Bool {
        guard let version, !version.isEmpty else { return false }
        guard defaults.string(forKey: lastRequestedVersionKey) != version else { return false }

        // Record before handing control to StoreKit so a repeated completion or
        // a suppressed system request cannot ask again for this app version.
        defaults.set(version, forKey: lastRequestedVersionKey)
        request()
        return true
    }
}
