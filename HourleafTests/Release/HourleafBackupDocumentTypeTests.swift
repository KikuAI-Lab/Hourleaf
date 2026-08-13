import UniformTypeIdentifiers
import XCTest
@testable import Hourleaf

final class HourleafBackupDocumentTypeTests: XCTestCase {
    func testRuntimeTypeUsesStableExportedIdentifierAndJSONConformance() {
        XCTAssertEqual(UTType.hourleafBackup.identifier, "com.kikuai.hourleaf.backup")
        XCTAssertTrue(UTType.hourleafBackup.conforms(to: .json))
        XCTAssertTrue(UTType.hourleafBackup.isDeclared)
        XCTAssertEqual(UTType.hourleafBackup.preferredFilenameExtension, "hourleafbackup")
    }

    func testHostedAppPackagesTheExportedTypeDeclaration() throws {
        let declarations = try XCTUnwrap(
            Bundle.main.infoDictionary?["UTExportedTypeDeclarations"] as? [[String: Any]]
        )
        XCTAssertEqual(declarations.count, 1)
        XCTAssertEqual(
            declarations.first?["UTTypeIdentifier"] as? String,
            "com.kikuai.hourleaf.backup"
        )
    }

    func testAppInfoDeclaresHourleafBackupFilenameAndMIMEType() throws {
        let infoURL = repositoryRoot
            .appendingPathComponent("Hourleaf")
            .appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: infoURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let declarations = try XCTUnwrap(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
        XCTAssertEqual(declarations.count, 1)
        let declaration = try XCTUnwrap(declarations.first)

        XCTAssertEqual(declaration["UTTypeIdentifier"] as? String, "com.kikuai.hourleaf.backup")
        XCTAssertEqual(declaration["UTTypeConformsTo"] as? [String], ["public.json"])

        let tags = try XCTUnwrap(declaration["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(tags["public.filename-extension"] as? [String], ["hourleafbackup"])
        XCTAssertEqual(
            tags["public.mime-type"] as? String,
            "application/vnd.kikuai.hourleaf.backup+json"
        )
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Release
            .deletingLastPathComponent() // HourleafTests
            .deletingLastPathComponent()
    }
}
