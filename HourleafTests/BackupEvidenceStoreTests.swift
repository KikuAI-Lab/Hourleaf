import Foundation
import XCTest
@testable import Hourleaf

final class BackupEvidenceStoreTests: XCTestCase {
    func testFirstEvidenceRoundTripsFromExpectedApplicationSupportPath() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let store = makeStore(root: sandbox)
        let evidence = sampleEvidence(verifiedAt: Date(timeIntervalSinceReferenceDate: 200))

        try await store.replace(with: evidence)

        let readback = try await store.read()
        XCTAssertEqual(readback, evidence)
        let path = sandbox
            .appendingPathComponent("Hourleaf", isDirectory: true)
            .appendingPathComponent("BackupEvidence", isDirectory: true)
            .appendingPathComponent("last-verified-export-v1.json", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }

    func testReplacementOverwritesPriorValidEvidence() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let store = makeStore(root: sandbox)
        let first = sampleEvidence(verifiedAt: Date(timeIntervalSinceReferenceDate: 200))
        let second = sampleEvidence(
            verifiedAt: Date(timeIntervalSinceReferenceDate: 400),
            checksum: String(repeating: "b", count: 64),
            digest: String(repeating: "c", count: 64)
        )

        try await store.replace(with: first)
        try await store.replace(with: second)

        let actual = try await store.read()
        XCTAssertEqual(actual, second)
    }

    func testFinalReadbackFailurePreservesPriorValidEvidence() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let first = sampleEvidence(verifiedAt: Date(timeIntervalSinceReferenceDate: 200))
        let finalURL = sandbox
            .appendingPathComponent("Hourleaf", isDirectory: true)
            .appendingPathComponent("BackupEvidence", isDirectory: true)
            .appendingPathComponent("last-verified-export-v1.json", isDirectory: false)

        let initialStore = makeStore(root: sandbox)
        try await initialStore.replace(with: first)

        let failingStore = makeStore(
            root: sandbox,
            dataReader: { url in
                if url.standardizedFileURL == finalURL.standardizedFileURL {
                    return Data("not json".utf8)
                }
                return try Data(contentsOf: url)
            }
        )

        let second = sampleEvidence(
            verifiedAt: Date(timeIntervalSinceReferenceDate: 500),
            checksum: String(repeating: "d", count: 64),
            digest: String(repeating: "e", count: 64)
        )

        await assertThrowsErrorAsync(try await failingStore.replace(with: second)) {
            XCTAssertEqual($0 as? VerifiedExportEvidenceStoreError, .invalidEvidence)
        }

        let preserved = try await initialStore.read()
        XCTAssertEqual(preserved, first)
    }

    private func makeSandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupEvidenceStoreTests-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStore(
        root: URL,
        dataReader: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) -> VerifiedExportEvidenceStore {
        VerifiedExportEvidenceStore(
            applicationSupportDirectory: { root },
            dataReader: dataReader
        )
    }

    private func sampleEvidence(
        verifiedAt: Date,
        checksum: String = String(repeating: "a", count: 64),
        digest: String = String(repeating: "b", count: 64)
    ) -> VerifiedExportEvidenceV1 {
        VerifiedExportEvidenceV1(
            schemaVersion: 1,
            exportedAt: Date(timeIntervalSinceReferenceDate: 100),
            verifiedAt: verifiedAt,
            artifactChecksum: checksum,
            recordsDigest: digest,
            byteCount: 1_024,
            totalRecordCount: 42
        )
    }
}

private func assertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown.", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
