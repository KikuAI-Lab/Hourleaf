import Foundation
import XCTest
@testable import Hourleaf

@MainActor
final class QuickEntryURLRoutingTests: XCTestCase {
    func testColdURLBuilderAndPendingRouterRouteUseExactConfiguredScheme() throws {
        let bundleRoot = try makeBundleRoot(
            name: "hourleaf-quick-entry-cold",
            scheme: "hourleaf"
        )
        defer { cleanup(bundleRoot) }
        let bundle = try XCTUnwrap(Bundle(url: bundleRoot))
        let expected = try XCTUnwrap(URL(string: "hourleaf://quick-entry"))

        XCTAssertEqual(HourleafQuickEntryURL.makeURL(bundle: bundle), expected)
        let router = AppRouter()
        XCTAssertTrue(router.routeIfQuickEntryURL(expected, bundle: bundle))
        XCTAssertEqual(router.pendingRoute, .quickEntry)
    }

    func testWarmRouteAcceptsOnlyExactConfiguredURLAndIgnoresPayloadVariants() throws {
        let bundleRoot = try makeBundleRoot(
            name: "hourleaf-quick-entry-warm",
            scheme: "hourleaf-local"
        )
        defer { cleanup(bundleRoot) }
        let bundle = try XCTUnwrap(Bundle(url: bundleRoot))
        let router = AppRouter()
        let valid = try XCTUnwrap(URL(string: "hourleaf-local://quick-entry"))

        XCTAssertTrue(router.routeIfQuickEntryURL(valid, bundle: bundle))
        XCTAssertEqual(router.consumePendingRoute(), .quickEntry)

        let invalidURLs = [
            "hourleaf://quick-entry",
            "hourleaf-local://other",
            "hourleaf-local://quick-entry?minutes=60",
            "hourleaf-local://quick-entry#payload"
        ].compactMap(URL.init(string:))

        for invalid in invalidURLs {
            XCTAssertFalse(router.routeIfQuickEntryURL(invalid, bundle: bundle))
            XCTAssertNil(router.pendingRoute)
        }
    }

    func testWarmLauncherRoutesConfiguredURLThroughItsExistingRouter() throws {
        let bundleRoot = try makeBundleRoot(
            name: "hourleaf-quick-entry-launcher",
            scheme: "hourleaf"
        )
        defer { cleanup(bundleRoot) }
        let bundle = try XCTUnwrap(Bundle(url: bundleRoot))
        let launcher = HourleafAppLauncher(arguments: ["-uiTesting"])
        let url = try XCTUnwrap(URL(string: "hourleaf://quick-entry"))

        launcher.handleOpenURL(url, bundle: bundle)

        guard case let .ready(session) = launcher.state else {
            return XCTFail("UI-test launcher should expose a warm app session.")
        }
        XCTAssertEqual(session.router.pendingRoute, .quickEntry)
    }

    func testPendingRouteSurvivesUntilRootConsumesIt() throws {
        let bundleRoot = try makeBundleRoot(
            name: "hourleaf-quick-entry-pending",
            scheme: "hourleaf-slice3smoke"
        )
        defer { cleanup(bundleRoot) }
        let bundle = try XCTUnwrap(Bundle(url: bundleRoot))
        let router = AppRouter()
        let url = try XCTUnwrap(URL(string: "hourleaf-slice3smoke://quick-entry"))

        XCTAssertTrue(router.routeIfQuickEntryURL(url, bundle: bundle))
        XCTAssertEqual(router.pendingRoute, .quickEntry)
        XCTAssertEqual(router.consumePendingRoute(), .quickEntry)
        XCTAssertNil(router.pendingRoute)
    }

    private func makeBundleRoot(name: String, scheme: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HourleafQuickEntryURLTests-\(name).bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let info: [String: Any] = [HourleafQuickEntryURL.infoKey: scheme]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(to: root.appendingPathComponent("Info.plist"), options: .atomic)
        return root
    }

    private func cleanup(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }
}
