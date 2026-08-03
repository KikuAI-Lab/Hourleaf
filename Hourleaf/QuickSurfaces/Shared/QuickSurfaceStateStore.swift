import Foundation
import Darwin

enum QuickSurfaceStateStoreError: LocalizedError, Equatable, Sendable {
    case missingFile
    case invalidRoot
    case unavailableRoot
    case pathEscape
    case symlinkDetected
    case protectedBeforeFirstUnlock
    case corrupt
    case unsupportedVersion
    case coordinationFailed
    case readFailed
    case writeFailed
    case attributeApplyFailed
    case protectionReadbackFailed
    case backupExclusionReadbackFailed
    case readbackMismatch
    case invalidInitialRevision
    case invalidRevisionTransition
    case revisionUnavailable
    case currentStateMismatch

    var errorDescription: String? {
        switch self {
        case .missingFile:
            return "Quick-surface state is missing."
        case .invalidRoot:
            return "Quick-surface state root is invalid."
        case .unavailableRoot:
            return "Quick-surface state root is unavailable."
        case .pathEscape:
            return "Quick-surface state path escaped its root."
        case .symlinkDetected:
            return "Quick-surface state path contains a symlink."
        case .protectedBeforeFirstUnlock:
            return "Quick-surface state is unavailable before first unlock."
        case .corrupt:
            return "Quick-surface state is corrupt."
        case .unsupportedVersion:
            return "Quick-surface state uses an unsupported version."
        case .coordinationFailed:
            return "Quick-surface state coordination failed."
        case .readFailed:
            return "Quick-surface state could not be read."
        case .writeFailed:
            return "Quick-surface state could not be written."
        case .attributeApplyFailed:
            return "Quick-surface state attributes could not be applied."
        case .protectionReadbackFailed:
            return "Quick-surface state protection could not be verified."
        case .backupExclusionReadbackFailed:
            return "Quick-surface state backup exclusion could not be verified."
        case .readbackMismatch:
            return "Quick-surface state readback did not match the committed state."
        case .invalidInitialRevision:
            return "Quick-surface state must start at revision 1."
        case .invalidRevisionTransition:
            return "Quick-surface state revision transition is invalid."
        case .revisionUnavailable:
            return "Quick-surface state revision is unavailable."
        case .currentStateMismatch:
            return "Quick-surface state no longer matches the expected state."
        }
    }
}

enum QuickSurfaceStateStoreFaultPoint: Equatable, Sendable {
    case beforePublish(targetURL: URL, temporaryURL: URL)
    case afterPublishBeforeReadback(targetURL: URL)
}

struct QuickSurfaceStateStoreFaults: Sendable {
    var inject: @Sendable (QuickSurfaceStateStoreFaultPoint) throws -> Void

    init(
        inject: @escaping @Sendable (QuickSurfaceStateStoreFaultPoint) throws -> Void = { _ in }
    ) {
        self.inject = inject
    }
}

struct QuickSurfaceStateStoreAttributeIO: Sendable {
    var setBackupExclusion: @Sendable (URL) throws -> Void
    var readBackupExclusion: @Sendable (URL) throws -> Bool
    var setProtection: @Sendable (URL) throws -> Void
    var readProtection: @Sendable (URL) throws -> FileProtectionType?

    init(
        setBackupExclusion: @escaping @Sendable (URL) throws -> Void = { url in
            var mutableURL = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try mutableURL.setResourceValues(values)
        },
        readBackupExclusion: @escaping @Sendable (URL) throws -> Bool = { url in
            try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
        },
        setProtection: @escaping @Sendable (URL) throws -> Void = { url in
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        },
        readProtection: @escaping @Sendable (URL) throws -> FileProtectionType? = { url in
            try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey] as? FileProtectionType
        }
    ) {
        self.setBackupExclusion = setBackupExclusion
        self.readBackupExclusion = readBackupExclusion
        self.setProtection = setProtection
        self.readProtection = readProtection
    }
}

// FileManager and NSFileCoordinator are Foundation reference types without Sendable
// annotations. Store access is synchronous, uses a fresh coordinator per access,
// and never crosses an async boundary inside coordinated work.
struct QuickSurfaceStateStoreV1: @unchecked Sendable {
    static let relativePathComponents = [
        "Library",
        "Application Support",
        "QuickSurfaces",
        "hourleaf-quick-state-v1.json"
    ]
    static let maximumFileBytes = 16 * 1_024
    static let fileProtection = FileProtectionType.completeUntilFirstUserAuthentication

    let rootDirectory: URL
    let fileManager: FileManager
    let faults: QuickSurfaceStateStoreFaults
    let attributeIO: QuickSurfaceStateStoreAttributeIO

    init(
        rootDirectory: URL,
        fileManager: FileManager = .default,
        faults: QuickSurfaceStateStoreFaults = .init(),
        attributeIO: QuickSurfaceStateStoreAttributeIO = .init()
    ) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
        self.faults = faults
        self.attributeIO = attributeIO
    }

    func read() throws -> QuickSurfaceStateV1 {
        let paths = try makePaths()
        try validateRoot(paths.root)

        var coordinationError: NSError?
        var result: Result<QuickSurfaceStateV1, Error> = .failure(QuickSurfaceStateStoreError.coordinationFailed)
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: paths.file, options: [], error: &coordinationError) { coordinatedURL in
            result = Result {
                try validateFixedPath(paths, allowMissingFile: true)
                guard try fileExists(at: coordinatedURL) else {
                    throw QuickSurfaceStateStoreError.missingFile
                }
                try validateExactPath(expected: paths.file, actual: coordinatedURL, root: paths.root, expectFile: true)
                return try decodeState(at: coordinatedURL, directoryURL: paths.directory, root: paths.root)
            }
        }

        if let coordinationError {
            throw mapUnknownError(coordinationError, defaultError: .coordinationFailed)
        }
        return try result.get()
    }

    func write(_ state: QuickSurfaceStateV1) throws {
        let persisted: QuickSurfaceStateV1
        if state.revision == 1 {
            persisted = try createIfAbsent(state)
        } else {
            persisted = try replace { _ in state }
        }
        guard persisted == state else {
            throw QuickSurfaceStateStoreError.currentStateMismatch
        }
    }

    func createIfAbsent(_ initialState: QuickSurfaceStateV1) throws -> QuickSurfaceStateV1 {
        try replace { current in
            current ?? initialState
        }
    }

    func replace(
        expectedCurrent: QuickSurfaceStateV1? = nil,
        transform: (QuickSurfaceStateV1?) throws -> QuickSurfaceStateV1
    ) throws -> QuickSurfaceStateV1 {
        let paths = try makePaths()
        try validateRoot(paths.root)

        var coordinationError: NSError?
        var result: Result<QuickSurfaceStateV1, Error> = .failure(QuickSurfaceStateStoreError.coordinationFailed)
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: paths.file, options: .forMerging, error: &coordinationError) { coordinatedURL in
            result = Result {
                try validateFixedPath(paths, allowMissingFile: true)
                try validateExactPath(expected: paths.file, actual: coordinatedURL, root: paths.root, expectFile: true)
                let currentState = try decodeOptionalState(
                    at: coordinatedURL,
                    expectedFileURL: paths.file,
                    directoryURL: paths.directory,
                    root: paths.root
                )
                if let expectedCurrent, currentState != expectedCurrent {
                    throw QuickSurfaceStateStoreError.currentStateMismatch
                }
                if currentState?.revision == .max {
                    throw QuickSurfaceStateStoreError.revisionUnavailable
                }

                let nextState = try transform(currentState)
                if currentState == nextState, let currentState {
                    try applyRequiredAttributes(to: paths.directory)
                    try applyRequiredAttributes(to: coordinatedURL)
                    return currentState
                }

                try validateRevisionTransition(current: currentState, next: nextState)
                try ensureParentDirectoryExists(paths.directory, root: paths.root)
                try validateFixedPath(paths, allowMissingFile: true)
                try applyRequiredAttributes(to: paths.directory)

                let payload = try QuickSurfaceStateV1.encodeCanonical(nextState)
                let temporaryURL = paths.directory.appendingPathComponent(
                    "pending-\(UUID().uuidString).json",
                    isDirectory: false
                )

                try ensureContained(root: paths.root, candidate: temporaryURL)
                try faults.inject(.beforePublish(targetURL: coordinatedURL, temporaryURL: temporaryURL))
                try publish(payload: payload, to: coordinatedURL, temporaryURL: temporaryURL, root: paths.root)
                try applyRequiredAttributes(to: coordinatedURL)
                try faults.inject(.afterPublishBeforeReadback(targetURL: coordinatedURL))

                let reread = try boundedRead(at: coordinatedURL)
                guard reread == payload else {
                    throw QuickSurfaceStateStoreError.readbackMismatch
                }
                _ = try decodeStoreState(reread)
                return nextState
            }
        }

        if let coordinationError {
            throw mapUnknownError(coordinationError, defaultError: .coordinationFailed)
        }
        return try result.get()
    }

    private func makePaths() throws -> Paths {
        guard rootDirectory.isFileURL else {
            throw QuickSurfaceStateStoreError.invalidRoot
        }

        let root = rootDirectory.standardizedFileURL
        let library = root.appendingPathComponent(Self.relativePathComponents[0], isDirectory: true)
        let applicationSupport = library.appendingPathComponent(Self.relativePathComponents[1], isDirectory: true)
        let directory = applicationSupport.appendingPathComponent(Self.relativePathComponents[2], isDirectory: true)
        let file = directory.appendingPathComponent(Self.relativePathComponents[3], isDirectory: false)
        try ensureContained(root: root, candidate: file)
        return Paths(root: root, library: library, applicationSupport: applicationSupport, directory: directory, file: file)
    }

    private func validateRoot(_ root: URL) throws {
        if try isSymbolicLink(at: root) {
            throw QuickSurfaceStateStoreError.symlinkDetected
        }
        guard try fileExists(at: root) else {
            throw QuickSurfaceStateStoreError.unavailableRoot
        }
        let values = try resourceValues(
            for: root,
            keys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true else {
            throw QuickSurfaceStateStoreError.unavailableRoot
        }
        guard values.isSymbolicLink != true else {
            throw QuickSurfaceStateStoreError.symlinkDetected
        }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedRoot == root else {
            throw QuickSurfaceStateStoreError.symlinkDetected
        }
        try ensureResolvedContained(root: root, existing: root)
    }

    private func validateFixedPath(_ paths: Paths, allowMissingFile: Bool) throws {
        try validateExistingAccessPath(paths.root, root: paths.root, expectFile: false)
        try validateExistingAncestor(paths.library, root: paths.root)
        try validateExistingAncestor(paths.applicationSupport, root: paths.root)
        try validateExistingAncestor(paths.directory, root: paths.root)

        if try isSymbolicLink(at: paths.file) {
            throw QuickSurfaceStateStoreError.symlinkDetected
        }
        if allowMissingFile {
            if try fileExists(at: paths.file) {
                try validateExistingAccessPath(paths.file, root: paths.root, expectFile: true)
            }
        } else {
            try validateExistingAccessPath(paths.file, root: paths.root, expectFile: true)
        }
    }

    private func validateExistingAncestor(_ url: URL, root: URL) throws {
        guard try fileExists(at: url) else { return }
        try validateExistingAccessPath(url, root: root, expectFile: false)
    }

    private func validateExistingAccessPath(_ url: URL, root: URL, expectFile: Bool) throws {
        if try isSymbolicLink(at: url) {
            throw QuickSurfaceStateStoreError.symlinkDetected
        }
        guard try fileExists(at: url) else {
            throw expectFile ? QuickSurfaceStateStoreError.missingFile : QuickSurfaceStateStoreError.invalidRoot
        }
        let values = try resourceValues(for: url, keys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw QuickSurfaceStateStoreError.symlinkDetected
        }

        if expectFile {
            guard values.isRegularFile == true else {
                throw QuickSurfaceStateStoreError.missingFile
            }
        } else {
            guard values.isDirectory == true else {
                throw QuickSurfaceStateStoreError.invalidRoot
            }
        }

        try ensureContained(root: root, candidate: url)
        try ensureResolvedContained(root: root, existing: url)
    }

    private func validateExactPath(expected: URL, actual: URL, root: URL, expectFile: Bool) throws {
        try ensureContained(root: root, candidate: actual)
        guard actual.standardizedFileURL == expected.standardizedFileURL else {
            throw QuickSurfaceStateStoreError.pathEscape
        }
        if try fileExists(at: actual) {
            try validateExistingAccessPath(actual, root: root, expectFile: expectFile)
            let resolvedExpected = expected.resolvingSymlinksInPath().standardizedFileURL
            let resolvedActual = actual.resolvingSymlinksInPath().standardizedFileURL
            guard resolvedExpected == resolvedActual else {
                throw QuickSurfaceStateStoreError.pathEscape
            }
        }
    }

    private func ensureParentDirectoryExists(_ directory: URL, root: URL) throws {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw mapUnknownError(error, defaultError: .writeFailed)
        }
        try validateExistingAccessPath(directory, root: root, expectFile: false)
    }

    private func decodeOptionalState(
        at fileURL: URL,
        expectedFileURL: URL,
        directoryURL: URL,
        root: URL
    ) throws -> QuickSurfaceStateV1? {
        try validateFixedContainingDirectory(for: fileURL, root: root)
        guard try fileExists(at: fileURL) else {
            return nil
        }
        try validateExactPath(expected: expectedFileURL, actual: fileURL, root: root, expectFile: true)
        return try decodeState(at: fileURL, directoryURL: directoryURL, root: root)
    }

    private func decodeState(at fileURL: URL, directoryURL: URL, root: URL) throws -> QuickSurfaceStateV1 {
        try validateExistingAccessPath(directoryURL, root: root, expectFile: false)
        try applyRequiredAttributesReadbackOnly(to: directoryURL)
        try applyRequiredAttributesReadbackOnly(to: fileURL)
        let data = try boundedRead(at: fileURL)
        return try decodeStoreState(data)
    }

    private func decodeStoreState(_ data: Data) throws -> QuickSurfaceStateV1 {
        do {
            return try QuickSurfaceStateV1.decodeStrict(data)
        } catch let error as QuickSurfaceStateCodecError {
            throw mapCodecError(error)
        }
    }

    private func boundedRead(at url: URL) throws -> Data {
        let values = try resourceValues(for: url, keys: [.fileSizeKey])
        if let fileSize = values.fileSize, fileSize > Self.maximumFileBytes {
            throw QuickSurfaceStateStoreError.corrupt
        }

        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer {
                try? handle.close()
            }
            let data = try handle.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
            if data.count > Self.maximumFileBytes {
                throw QuickSurfaceStateStoreError.corrupt
            }
            return data
        } catch let error as QuickSurfaceStateStoreError {
            throw error
        } catch {
            throw mapUnknownError(error, defaultError: .readFailed)
        }
    }

    private func publish(payload: Data, to targetURL: URL, temporaryURL: URL, root: URL) throws {
        var published = false
        do {
            if try isSymbolicLink(at: temporaryURL) {
                throw QuickSurfaceStateStoreError.symlinkDetected
            }
            if try fileExists(at: temporaryURL) {
                try fileManager.removeItem(at: temporaryURL)
            }

            try payload.write(
                to: temporaryURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            try validateExistingAccessPath(temporaryURL, root: root, expectFile: true)
            try applyRequiredAttributes(to: temporaryURL)

            if try fileExists(at: targetURL) {
                _ = try fileManager.replaceItemAt(targetURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: targetURL)
            }
            published = true
            try validateExistingAccessPath(targetURL, root: root, expectFile: true)
        } catch let error as QuickSurfaceStateStoreError {
            if !published, try fileExists(at: temporaryURL) {
                try? fileManager.removeItem(at: temporaryURL)
            }
            throw error
        } catch {
            if !published, try fileExists(at: temporaryURL) {
                try? fileManager.removeItem(at: temporaryURL)
            }
            throw mapUnknownError(error, defaultError: .writeFailed)
        }
    }

    private func applyRequiredAttributes(to url: URL) throws {
        do {
            try attributeIO.setBackupExclusion(url)
            try attributeIO.setProtection(url)
        } catch {
            throw mapUnknownError(error, defaultError: .attributeApplyFailed)
        }

        do {
            guard try attributeIO.readBackupExclusion(url) else {
                throw QuickSurfaceStateStoreError.backupExclusionReadbackFailed
            }
        } catch let error as QuickSurfaceStateStoreError {
            throw error
        } catch {
            throw mapUnknownError(error, defaultError: .backupExclusionReadbackFailed)
        }

        do {
            guard try attributeIO.readProtection(url) == Self.fileProtection else {
                throw QuickSurfaceStateStoreError.protectionReadbackFailed
            }
        } catch let error as QuickSurfaceStateStoreError {
            throw error
        } catch {
            throw mapUnknownError(error, defaultError: .protectionReadbackFailed)
        }
    }

    private func applyRequiredAttributesReadbackOnly(to url: URL) throws {
        do {
            guard try attributeIO.readBackupExclusion(url) else {
                throw QuickSurfaceStateStoreError.backupExclusionReadbackFailed
            }
        } catch let error as QuickSurfaceStateStoreError {
            throw error
        } catch {
            throw mapUnknownError(error, defaultError: .backupExclusionReadbackFailed)
        }

        do {
            guard try attributeIO.readProtection(url) == Self.fileProtection else {
                throw QuickSurfaceStateStoreError.protectionReadbackFailed
            }
        } catch let error as QuickSurfaceStateStoreError {
            throw error
        } catch {
            throw mapUnknownError(error, defaultError: .protectionReadbackFailed)
        }
    }

    private func validateRevisionTransition(current: QuickSurfaceStateV1?, next: QuickSurfaceStateV1) throws {
        if next.revision == .max {
            if current == nil {
                throw QuickSurfaceStateStoreError.invalidInitialRevision
            }
            throw QuickSurfaceStateStoreError.invalidRevisionTransition
        }

        guard let current else {
            guard next.revision == 1 else {
                throw QuickSurfaceStateStoreError.invalidInitialRevision
            }
            return
        }

        guard current.revision != .max else {
            throw QuickSurfaceStateStoreError.revisionUnavailable
        }

        let expected = current.revision &+ 1
        guard next.revision == expected else {
            throw QuickSurfaceStateStoreError.invalidRevisionTransition
        }
    }

    private func validateFixedContainingDirectory(for fileURL: URL, root: URL) throws {
        let directory = fileURL.deletingLastPathComponent()
        if try fileExists(at: directory) {
            try validateExistingAccessPath(directory, root: root, expectFile: false)
        }
    }

    private func resourceValues(
        for url: URL,
        keys: Set<URLResourceKey>
    ) throws -> URLResourceValues {
        do {
            return try url.resourceValues(forKeys: keys)
        } catch {
            throw mapUnknownError(error, defaultError: .readFailed)
        }
    }

    private func fileExists(at url: URL) throws -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    private func isSymbolicLink(at url: URL) throws -> Bool {
        var metadata = stat()
        var status: Int32 = -1
        let hadRepresentation = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            status = Darwin.lstat(path, &metadata)
            return true
        }
        guard hadRepresentation else {
            throw QuickSurfaceStateStoreError.invalidRoot
        }
        if status == 0 {
            return (metadata.st_mode & S_IFMT) == S_IFLNK
        }

        let code = errno
        if code == ENOENT || code == ENOTDIR {
            return false
        }
        throw mapUnknownError(
            NSError(domain: NSPOSIXErrorDomain, code: Int(code)),
            defaultError: .readFailed
        )
    }

    private func ensureContained(root: URL, candidate: URL) throws {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        guard
            candidateComponents.count >= rootComponents.count,
            Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
        else {
            throw QuickSurfaceStateStoreError.pathEscape
        }
    }

    private func ensureResolvedContained(root: URL, existing: URL) throws {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedExisting = existing.resolvingSymlinksInPath().standardizedFileURL
        try ensureContained(root: resolvedRoot, candidate: resolvedExisting)
    }

    private func mapCodecError(_ error: QuickSurfaceStateCodecError) -> QuickSurfaceStateStoreError {
        switch error {
        case .unsupportedVersion:
            return .unsupportedVersion
        default:
            return .corrupt
        }
    }

    private func mapUnknownError(
        _ error: Error,
        defaultError: QuickSurfaceStateStoreError
    ) -> QuickSurfaceStateStoreError {
        if let storeError = error as? QuickSurfaceStateStoreError {
            return storeError
        }
        if let codecError = error as? QuickSurfaceStateCodecError {
            return mapCodecError(codecError)
        }
        if isProtectedBeforeUnlockError(error) {
            return .protectedBeforeFirstUnlock
        }
        return defaultError
    }

    private func isProtectedBeforeUnlockError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == EACCES || nsError.code == EPERM {
            return true
        }

        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return true
            default:
                break
            }
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isProtectedBeforeUnlockError(underlying)
        }
        return false
    }
}

private extension QuickSurfaceStateStoreV1 {
    struct Paths {
        let root: URL
        let library: URL
        let applicationSupport: URL
        let directory: URL
        let file: URL
    }
}
