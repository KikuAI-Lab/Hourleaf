import Foundation
@testable import Hourleaf

enum QuickSurfaceStoreTestSupport {
    static func makeSandboxRoot(name: String = UUID().uuidString) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("QuickSurfaceStateStoreTests-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func stateDirectoryURL(root: URL) -> URL {
        root
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("QuickSurfaces", isDirectory: true)
    }

    static func stateFileURL(root: URL) -> URL {
        stateDirectoryURL(root: root)
            .appendingPathComponent("hourleaf-quick-state-v1.json", isDirectory: false)
    }

    static func makeHiddenState(revision: UInt64) throws -> QuickSurfaceStateV1 {
        QuickSurfaceStateV1(
            revision: revision,
            projection: try QuickSurfaceProjectionV1(
                privacyMode: .hideTotals,
                monthKey: nil,
                timeZoneIdentifier: nil,
                serviceMinutes: nil,
                creditMinutes: nil,
                generatedAtEpochSeconds: 100
            ),
            timerEnabled: false,
            timer: .idle
        )
    }

    static func makeShownState(revision: UInt64, serviceMinutes: Int = 125, creditMinutes: Int = 7) throws -> QuickSurfaceStateV1 {
        QuickSurfaceStateV1(
            revision: revision,
            projection: try QuickSurfaceProjectionV1(
                privacyMode: .showTotals,
                monthKey: "2026-08",
                timeZoneIdentifier: "Europe/Uzhgorod",
                serviceMinutes: serviceMinutes,
                creditMinutes: creditMinutes,
                generatedAtEpochSeconds: 123.25
            ),
            timerEnabled: true,
            timer: .running(
                try .init(
                    sessionID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    startedAtEpochSeconds: 100,
                    startedSystemUptimeSeconds: 20
                )
            )
        )
    }

    static func writeStateFile(_ state: QuickSurfaceStateV1, root: URL) throws {
        try writeData(QuickSurfaceStateV1.encodeCanonical(state), to: stateFileURL(root: root))
    }

    static func writeData(_ data: Data, to fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(
            to: fileURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        try applyRequiredAttributes(to: fileURL.deletingLastPathComponent())
        try applyRequiredAttributes(to: fileURL)
    }

    static func applyRequiredAttributes(to url: URL) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    static func makeAttributeLedger() -> QuickSurfaceStoreAttributeLedger {
        QuickSurfaceStoreAttributeLedger()
    }

    static func primeRequiredAttributes(
        root: URL,
        ledger: QuickSurfaceStoreAttributeLedger
    ) {
        let directoryURL = stateDirectoryURL(root: root)
        let fileURL = stateFileURL(root: root)
        ledger.markBackupExcluded(directoryURL)
        ledger.markProtected(directoryURL)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            ledger.markBackupExcluded(fileURL)
            ledger.markProtected(fileURL)
        }
    }

    static func simulatedAttributeIO(
        ledger: QuickSurfaceStoreAttributeLedger,
        failSetBackupExclusion: (@Sendable (URL) -> Bool)? = nil,
        failSetProtection: (@Sendable (URL) -> Bool)? = nil,
        failReadBackupExclusion: (@Sendable (URL) -> Bool)? = nil,
        failReadProtection: (@Sendable (URL) -> Bool)? = nil
    ) -> QuickSurfaceStateStoreAttributeIO {
        QuickSurfaceStateStoreAttributeIO(
            setBackupExclusion: { url in
                if failSetBackupExclusion?(url) == true {
                    throw QuickSurfaceStoreInjectedError.marker
                }
                ledger.markBackupExcluded(url)
            },
            readBackupExclusion: { url in
                if failReadBackupExclusion?(url) == true {
                    return false
                }
                return ledger.isBackupExcluded(url)
            },
            setProtection: { url in
                if failSetProtection?(url) == true {
                    throw QuickSurfaceStoreInjectedError.marker
                }
                ledger.markProtected(url)
            },
            readProtection: { url in
                if failReadProtection?(url) == true {
                    return nil
                }
                return ledger.isProtected(url)
                    ? FileProtectionType.completeUntilFirstUserAuthentication
                    : nil
            }
        )
    }
}

enum QuickSurfaceStoreInjectedError: Error {
    case marker
}

final class QuickSurfaceStoreAttributeLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var backupExcludedPaths: Set<String> = []
    private var protectedPaths: Set<String> = []

    func markBackupExcluded(_ url: URL) {
        lock.lock()
        backupExcludedPaths.insert(url.standardizedFileURL.path)
        lock.unlock()
    }

    func isBackupExcluded(_ url: URL) -> Bool {
        lock.lock()
        let result = backupExcludedPaths.contains(url.standardizedFileURL.path)
        lock.unlock()
        return result
    }

    func markProtected(_ url: URL) {
        lock.lock()
        protectedPaths.insert(url.standardizedFileURL.path)
        lock.unlock()
    }

    func isProtected(_ url: URL) -> Bool {
        lock.lock()
        let result = protectedPaths.contains(url.standardizedFileURL.path)
        lock.unlock()
        return result
    }
}
