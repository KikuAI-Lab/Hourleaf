import Foundation

/// Builds and validates the one URL used to open Hourleaf's existing quick
/// entry home. The scheme is supplied by the host and extension bundles so
/// local smoke identifiers can never be embedded in source or URL payloads.
struct HourleafQuickEntryURL {
    static let infoKey = "HourleafQuickEntryURLScheme"
    static let path = "quick-entry"

    /// Returns the configured scheme only when it is already strict lowercase
    /// ASCII URL-scheme syntax. No normalization is performed at this
    /// boundary: an uppercase or whitespace-bearing value is unavailable.
    static func resolveScheme(bundle: Bundle = .main) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: infoKey) as? String,
              isValidScheme(value)
        else {
            return nil
        }
        return value
    }

    /// Builds exactly `<scheme>://quick-entry`, without query, fragment, or
    /// user-provided data.
    static func makeURL(bundle: Bundle = .main) -> URL? {
        guard let scheme = resolveScheme(bundle: bundle),
              let url = URL(string: "\(scheme)://\(path)"),
              url.scheme == scheme,
              url.host == path,
              url.path.isEmpty,
              url.query == nil,
              url.fragment == nil,
              url.user == nil,
              url.password == nil,
              url.port == nil
        else {
            return nil
        }
        return url
    }

    /// Matches the complete URL, not merely its scheme or host. This prevents
    /// query strings and alternate paths from becoming an accidental route.
    static func matches(
        url: URL,
        bundle: Bundle = .main
    ) -> Bool {
        guard let expected = makeURL(bundle: bundle) else { return false }
        return url.absoluteString == expected.absoluteString
    }

    static func matches(
        _ url: URL,
        bundle: Bundle = .main
    ) -> Bool {
        matches(url: url, bundle: bundle)
    }

    static func isValidScheme(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard let first = bytes.first, isLowercaseASCIIAlpha(first) else {
            return false
        }
        return bytes.dropFirst().allSatisfy { byte in
            isLowercaseASCIIAlpha(byte)
                || isASCIIDigit(byte)
                || byte == 0x2B // +
                || byte == 0x2D // -
                || byte == 0x2E // .
        }
    }

    private static func isLowercaseASCIIAlpha(_ byte: UInt8) -> Bool {
        (0x61...0x7A).contains(byte)
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
    }
}
