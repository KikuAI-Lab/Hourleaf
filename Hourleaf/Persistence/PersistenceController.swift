@preconcurrency import CoreData
import Foundation

/// The only persistent-store shapes Hourleaf is allowed to open. Restore
/// staging always uses `localOnlySQLite`; an iCloud-connected live store is
/// deliberately never staged or replaced.
enum PersistentStoreMode: String, Equatable, Sendable {
    case inMemory
    case localOnlySQLite
    case privateCloudSQLite

    var isCloudBacked: Bool {
        self == .privateCloudSQLite
    }
}

/// A value description of the live store. It intentionally contains no
/// `NSPersistentStore` instance: those instances belong to a container and are
/// invalid once a transition closes that container.
struct PersistentStoreDescriptor: Equatable, Sendable {
    let mode: PersistentStoreMode
    let url: URL?

    var isSQLite: Bool {
        mode != .inMemory
    }
}

/// The exact disk store that a coordinator operation may touch while the live
/// container is closed. Keeping this as a distinct type prevents an in-memory
/// or CloudKit descriptor from being passed into whole-store replacement APIs.
struct ClosedPersistentStoreDescriptor: Equatable, Sendable {
    let url: URL
    let mode: PersistentStoreMode
    let storeType: String
    let usesPersistentHistory: Bool
    let postsRemoteChangeNotifications: Bool
    let fileProtection: String
}

enum PersistentStoreArtifactPurpose: Equatable, Sendable {
    case staging
    case evidence
}

/// An opaque, validated path for a coordinator-owned transition file. Callers
/// cannot pass a bare URL to copy, replace, or destroy APIs; the path must be
/// minted below an explicit application-owned directory using one file name.
struct PersistentStoreArtifact: Equatable, Sendable {
    fileprivate let url: URL
    fileprivate let purpose: PersistentStoreArtifactPurpose
    private let token: UUID

    static func make(
        in directory: URL,
        named filename: String,
        purpose: PersistentStoreArtifactPurpose
    ) throws -> Self {
        guard
            !filename.isEmpty,
            filename == URL(fileURLWithPath: filename).lastPathComponent,
            !filename.contains("/"),
            !filename.contains("\\"),
            filename != ".",
            filename != ".."
        else {
            throw PersistentStoreTransitionError.unexpectedStoreURL
        }
        let root = directory.standardizedFileURL
        let url = root.appendingPathComponent(filename, isDirectory: false).standardizedFileURL
        guard url.deletingLastPathComponent() == root else {
            throw PersistentStoreTransitionError.unexpectedStoreURL
        }
        return Self(url: url, purpose: purpose, token: UUID())
    }
}

/// A one-store cleanup authority minted only after the owning staging
/// controller has closed and retired its container. Holding this value never
/// retains the former Core Data stack.
final class PersistentStoreCleanupCapability: @unchecked Sendable {
    fileprivate struct Payload {
        let artifact: PersistentStoreArtifact
        let previousStoreUUID: String?
    }

    private let lock = NSLock()
    private let payload: Payload
    private var isConsumed = false

    fileprivate init(
        artifact: PersistentStoreArtifact,
        previousStoreUUID: String?
    ) {
        payload = Payload(
            artifact: artifact,
            previousStoreUUID: previousStoreUUID
        )
    }

    /// A failed attempt remains retryable. Once logical destruction is proved,
    /// later retries are no-ops so they cannot touch a reused staging slot.
    fileprivate func consume(
        _ operation: (Payload) throws -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isConsumed else { return }
        try operation(payload)
        isConsumed = true
    }
}

enum PersistentStoreTransitionError: LocalizedError, Equatable, Sendable {
    case unsupportedStoreMode(PersistentStoreMode)
    case storeAlreadyClosed
    case storeNotClosed
    case unexpectedStoreURL
    case transitionFailed(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedStoreMode(mode):
            "Hourleaf cannot replace a \(mode.rawValue) data store."
        case .storeAlreadyClosed:
            "Hourleaf data is already closed for maintenance."
        case .storeNotClosed:
            "Hourleaf must close local data before replacing it."
        case .unexpectedStoreURL:
            "Hourleaf refused a transition for an unexpected data-store location."
        case let .transitionFailed(message):
            "Hourleaf could not transition local data: \(message)"
        }
    }
}

enum PersistenceStartupError: LocalizedError, Equatable, Sendable {
    case missingStoreDescription
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingStoreDescription:
            "Hourleaf could not prepare its local data store."
        case let .loadFailed(message):
            "Hourleaf could not open its local data: \(message)"
        }
    }
}

/// Owns one open container at a time. A restore never swaps an individual
/// context or coordinator beneath the app: it first closes the current store,
/// lets Core Data perform the coordinator-level copy/replacement, then creates
/// a fresh `NSPersistentCloudKitContainer` before repository work resumes.
final class PersistenceController: @unchecked Sendable {
    static let shared = PersistenceController()

    private static let modelName = "HourleafModel"
    private static let cloudContainerIdentifier = "iCloud.com.kikuai.hourleaf"
    private static let protectionClass = FileProtectionType.completeUntilFirstUserAuthentication.rawValue

    let descriptor: PersistentStoreDescriptor

    private let lock = NSLock()
    private var activeContainer: NSPersistentCloudKitContainer
    private var activeStartupError: PersistenceStartupError?
    private var storeIsClosed = false
    private let ownedTransitionArtifact: PersistentStoreArtifact?
    private let transitionBoundaryObserver: @Sendable () -> Void
    private let reopenFailureMessage: @Sendable () -> String?

    /// Existing callers may read the live container, but only this controller
    /// can close it or create its successor.
    var container: NSPersistentCloudKitContainer {
        lock.lock()
        defer { lock.unlock() }
        return activeContainer
    }

    var startupError: PersistenceStartupError? {
        lock.lock()
        defer { lock.unlock() }
        return activeStartupError
    }

    var mode: PersistentStoreMode {
        descriptor.mode
    }

    init(
        inMemory: Bool = false,
        cloudSyncEnabled: Bool? = nil,
        storeURL: URL? = nil,
        transitionArtifact: PersistentStoreArtifact? = nil,
        transitionBoundaryObserver: @escaping @Sendable () -> Void = {},
        reopenFailureMessage: @escaping @Sendable () -> String? = { nil }
    ) {
        let mode: PersistentStoreMode
        if inMemory {
            mode = .inMemory
        } else if Self.shouldUseCloud(cloudSyncEnabled: cloudSyncEnabled) {
            mode = .privateCloudSQLite
        } else {
            mode = .localOnlySQLite
        }

        // NSPersistentContainer assigns the canonical default location for a
        // named model. Capture it once so closed-store operations are exact.
        let defaultURL = Self.defaultStoreURL()
        descriptor = PersistentStoreDescriptor(
            mode: mode,
            url: mode == .inMemory ? nil : (transitionArtifact?.url ?? storeURL ?? defaultURL)
        )
        ownedTransitionArtifact = transitionArtifact
        self.transitionBoundaryObserver = transitionBoundaryObserver
        self.reopenFailureMessage = reopenFailureMessage
        let opened = Self.makeContainer(descriptor: descriptor)
        activeContainer = opened.container
        activeStartupError = opened.error
    }

    /// A store is closed before *any* replacement/copy API is used. No raw
    /// SQLite, WAL, or SHM file operation is permitted in this type.
    func closePersistentStoreForTransition(
        validating validate: @escaping @Sendable (NSManagedObjectContext) throws -> Void = { _ in }
    ) throws -> ClosedPersistentStoreDescriptor {
        lock.lock()
        defer { lock.unlock() }

        guard descriptor.mode == .localOnlySQLite, let url = descriptor.url else {
            throw PersistentStoreTransitionError.unsupportedStoreMode(descriptor.mode)
        }
        guard !storeIsClosed else {
            throw PersistentStoreTransitionError.storeAlreadyClosed
        }
        guard activeStartupError == nil else {
            throw PersistentStoreTransitionError.transitionFailed(
                activeStartupError?.localizedDescription ?? "The local store did not open."
            )
        }

        let stores = activeContainer.persistentStoreCoordinator.persistentStores
        guard stores.count == 1,
              let store = stores.first,
              store.type == NSSQLiteStoreType,
              store.url?.standardizedFileURL == url.standardizedFileURL,
              activeContainer.persistentStoreDescriptions.count == 1,
              let description = activeContainer.persistentStoreDescriptions.first,
              description.type == NSSQLiteStoreType,
              description.url?.standardizedFileURL == url.standardizedFileURL,
              description.cloudKitContainerOptions == nil,
              Self.hasRequiredLocalOptions(description.options)
        else {
            throw PersistentStoreTransitionError.unexpectedStoreURL
        }

        do {
            let coordinator = activeContainer.persistentStoreCoordinator
            let validationContext = activeContainer.newBackgroundContext()
            validationContext.mergePolicy = NSMergePolicy(merge: .errorMergePolicyType)
            validationContext.undoManager = nil
            // The coordinator queue is the final barrier. A second context
            // which committed before it is acquired is included in `validate`;
            // one that arrives after it is acquired cannot save before removal.
            try coordinator.performAndWait {
                try validationContext.performAndWait {
                    try validate(validationContext)
                    validationContext.reset()
                }
                transitionBoundaryObserver()
                activeContainer.viewContext.performAndWait {
                    activeContainer.viewContext.reset()
                }
                try coordinator.remove(store)
            }
        } catch {
            throw PersistentStoreTransitionError.transitionFailed(error.localizedDescription)
        }
        storeIsClosed = true
        return ClosedPersistentStoreDescriptor(
            url: url,
            mode: descriptor.mode,
            storeType: store.type,
            usesPersistentHistory: (description.options[NSPersistentHistoryTrackingKey] as? NSNumber)?.boolValue == true,
            postsRemoteChangeNotifications: (description.options[NSPersistentStoreRemoteChangeNotificationPostOptionKey] as? NSNumber)?.boolValue == true,
            fileProtection: (description.options[NSPersistentStoreFileProtectionKey] as? String) ?? ""
        )
    }

    /// Core Data creates the physical evidence copy. This deliberately avoids
    /// filesystem copies, which can split a SQLite database from its WAL/SHM.
    func copyClosedStore(
        _ closed: ClosedPersistentStoreDescriptor,
        to destination: PersistentStoreArtifact
    ) throws {
        try validate(closed)
        guard destination.purpose == .evidence else {
            throw PersistentStoreTransitionError.unexpectedStoreURL
        }
        lock.lock()
        defer { lock.unlock() }
        guard storeIsClosed else { throw PersistentStoreTransitionError.storeNotClosed }
        do {
            try activeContainer.persistentStoreCoordinator.replacePersistentStore(
                at: destination.url,
                destinationOptions: Self.sqliteStoreOptions,
                withPersistentStoreFrom: closed.url,
                sourceOptions: Self.sqliteStoreOptions,
                type: .sqlite
            )
        } catch {
            throw PersistentStoreTransitionError.transitionFailed(error.localizedDescription)
        }
    }

    /// Replaces the exact closed live store using Core Data's coordinator API.
    /// Callers must validate the staged source before this operation.
    func replaceClosedStore(
        _ closed: ClosedPersistentStoreDescriptor,
        with source: PersistentStoreArtifact
    ) throws {
        try validate(closed)
        guard source.purpose == .staging else {
            throw PersistentStoreTransitionError.unexpectedStoreURL
        }
        lock.lock()
        defer { lock.unlock() }
        guard storeIsClosed else { throw PersistentStoreTransitionError.storeNotClosed }
        do {
            try activeContainer.persistentStoreCoordinator.replacePersistentStore(
                at: closed.url,
                destinationOptions: Self.sqliteStoreOptions,
                withPersistentStoreFrom: source.url,
                sourceOptions: Self.sqliteStoreOptions,
                type: .sqlite
            )
        } catch {
            throw PersistentStoreTransitionError.transitionFailed(error.localizedDescription)
        }
    }

    /// Coordinator-owned destruction is available only for task-owned
    /// temporary/evidence stores after a caller has independently decided that
    /// deletion is safe. It never targets the live descriptor.
    func destroyOwnedTransitionStore(_ artifact: PersistentStoreArtifact) throws {
        let capability = try relinquishOwnedTransitionStore(artifact)
        try Self.destroyRelinquishedTransitionStore(capability)
    }

    /// Retires the closed staging container and hands callers a typed cleanup
    /// authority that contains no Core Data objects. Candidate state must hold
    /// this value, never the former staging controller.
    func relinquishOwnedTransitionStore(
        _ artifact: PersistentStoreArtifact
    ) throws -> PersistentStoreCleanupCapability {
        lock.lock()
        defer { lock.unlock() }
        try validateOwnedStagingArtifact(artifact)
        guard storeIsClosed else { throw PersistentStoreTransitionError.storeNotClosed }
        let previousStoreUUID = try Self.storeUUID(at: artifact.url)

        let model = activeContainer.managedObjectModel
        let retiredReplacement = NSPersistentCloudKitContainer(
            name: Self.modelName,
            managedObjectModel: model
        )
        retiredReplacement.persistentStoreDescriptions = []
        activeContainer = retiredReplacement
        return PersistentStoreCleanupCapability(
            artifact: artifact,
            previousStoreUUID: previousStoreUUID
        )
    }

    /// Destroys only a relinquished task-owned staging artifact. The fresh
    /// coordinator is scoped to this call and no former container is retained.
    static func destroyRelinquishedTransitionStore(
        _ capability: PersistentStoreCleanupCapability,
        afterDestroy: () throws -> Void = {}
    ) throws {
        do {
            try capability.consume { payload in
                let artifact = payload.artifact
                guard artifact.purpose == .staging else {
                    throw PersistentStoreTransitionError.unexpectedStoreURL
                }
                if existingSQLiteFamilyURLs(for: artifact.url).isEmpty == false {
                    try autoreleasepool {
                        let modelContainer = NSPersistentCloudKitContainer(name: Self.modelName)
                        let destroyCoordinator = NSPersistentStoreCoordinator(
                            managedObjectModel: modelContainer.managedObjectModel
                        )
                        try destroyCoordinator.destroyPersistentStore(
                            at: artifact.url,
                            type: .sqlite,
                            options: Self.sqliteStoreOptions
                        )
                    }
                    try afterDestroy()
                }
                try verifyLogicallyDestroyedStore(
                    at: artifact.url,
                    previousStoreUUID: payload.previousStoreUUID
                )
            }
        } catch {
            if let transitionError = error as? PersistentStoreTransitionError {
                throw transitionError
            }
            throw PersistentStoreTransitionError.transitionFailed(error.localizedDescription)
        }
    }

    /// Read-only protection verification surface for the exact typed staging
    /// artifact. Existing WAL/SHM members are included; absent sidecars are not
    /// invented or touched.
    func existingOwnedTransitionStoreFiles(
        _ artifact: PersistentStoreArtifact
    ) throws -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        try validateOwnedStagingArtifact(artifact)
        let files = Self.existingSQLiteFamilyURLs(for: artifact.url)
        guard files.first == artifact.url else {
            throw PersistentStoreTransitionError.transitionFailed(
                "The task-owned SQLite store is missing."
            )
        }
        return files
    }

    /// Read-only discovery for the one deterministic app-owned staging slot.
    /// It accepts a partial SQLite family after process interruption, but never
    /// a directory, symlink, different filename, or path outside the exact root.
    static func existingOrphanedTransitionStoreFiles(
        _ artifact: PersistentStoreArtifact,
        in directory: URL,
        named filename: String
    ) throws -> [URL] {
        try validateExactOwnedSlot(artifact, in: directory, named: filename)
        let files = existingSQLiteFamilyURLs(for: artifact.url)
        for file in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw PersistentStoreTransitionError.unexpectedStoreURL
            }
        }
        return files
    }

    /// Mints cleanup authority for an exact deterministic slot left by a
    /// previous process. Readable stores retain their prior Core Data UUID;
    /// corrupt/partial stores use the subsequent zero-record proof instead.
    static func orphanedTransitionStoreCleanupCapability(
        _ artifact: PersistentStoreArtifact,
        in directory: URL,
        named filename: String
    ) throws -> PersistentStoreCleanupCapability {
        let files = try existingOrphanedTransitionStoreFiles(
            artifact,
            in: directory,
            named: filename
        )
        guard !files.isEmpty else {
            throw PersistentStoreTransitionError.unexpectedStoreURL
        }
        return PersistentStoreCleanupCapability(
            artifact: artifact,
            previousStoreUUID: try readableStoreUUID(at: artifact.url)
        )
    }

    /// Reopens using a brand-new container after a closed-store transition.
    /// Callers must wait for a repository validation readback before ending a
    /// maintenance lease.
    @discardableResult
    func reopenFreshContainerAfterTransition() -> PersistenceStartupError? {
        lock.lock()
        defer { lock.unlock() }
        guard storeIsClosed else {
            return .loadFailed(PersistentStoreTransitionError.storeNotClosed.localizedDescription)
        }
        if let failureMessage = reopenFailureMessage() {
            return .loadFailed(failureMessage)
        }
        let opened = Self.makeContainer(descriptor: descriptor)
        guard opened.error == nil else {
            // Keep the known-closed coordinator intact so a later retry does
            // not operate on a half-open replacement container.
            return opened.error
        }
        activeContainer = opened.container
        activeStartupError = nil
        storeIsClosed = false
        return nil
    }

    private func validate(_ closed: ClosedPersistentStoreDescriptor) throws {
        guard
            closed.mode == .localOnlySQLite,
            closed.storeType == NSSQLiteStoreType,
            closed.url == descriptor.url,
            closed.usesPersistentHistory,
            closed.postsRemoteChangeNotifications,
            closed.fileProtection == Self.protectionClass
        else {
            throw PersistentStoreTransitionError.unexpectedStoreURL
        }
    }

    private func validateOwnedStagingArtifact(_ artifact: PersistentStoreArtifact) throws {
        guard artifact == ownedTransitionArtifact,
              artifact.purpose == .staging,
              descriptor.mode == .localOnlySQLite,
              descriptor.url == artifact.url
        else {
            throw PersistentStoreTransitionError.unexpectedStoreURL
        }
    }

    private static func existingSQLiteFamilyURLs(for storeURL: URL) -> [URL] {
        let fileManager = FileManager.default
        let candidates = [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal", isDirectory: false),
            URL(fileURLWithPath: storeURL.path + "-shm", isDirectory: false)
        ]
        return candidates.filter { fileManager.fileExists(atPath: $0.path) }
    }

    private static func validateExactOwnedSlot(
        _ artifact: PersistentStoreArtifact,
        in directory: URL,
        named filename: String
    ) throws {
        let root = directory.standardizedFileURL
        let expected = root.appendingPathComponent(filename, isDirectory: false).standardizedFileURL
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard
            artifact.purpose == .staging,
            filename == URL(fileURLWithPath: filename).lastPathComponent,
            artifact.url == expected,
            expected.deletingLastPathComponent() == root,
            rootValues.isDirectory == true,
            rootValues.isSymbolicLink != true
        else {
            throw PersistentStoreTransitionError.unexpectedStoreURL
        }
    }

    private static func storeUUID(at url: URL) throws -> String {
        guard let identifier = try readableStoreUUID(at: url) else {
            throw PersistentStoreTransitionError.transitionFailed(
                "The task-owned SQLite store has no readable Core Data identity."
            )
        }
        return identifier
    }

    private static func readableStoreUUID(at url: URL) throws -> String? {
        let metadata: [String: Any]
        do {
            metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
                type: .sqlite,
                at: url,
                options: sqliteStoreOptions
            )
        } catch {
            return nil
        }
        guard let identifier = metadata[NSStoreUUIDKey] as? String, !identifier.isEmpty else {
            throw PersistentStoreTransitionError.transitionFailed(
                "The task-owned SQLite store returned an invalid Core Data identity."
            )
        }
        return identifier
    }

    private static func verifyLogicallyDestroyedStore(
        at url: URL,
        previousStoreUUID: String?
    ) throws {
        try autoreleasepool {
            let modelContainer = NSPersistentCloudKitContainer(name: modelName)
            let model = modelContainer.managedObjectModel
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
            let store = try coordinator.addPersistentStore(
                type: .sqlite,
                configuration: nil,
                at: url,
                options: sqliteStoreOptions
            )
            defer { try? coordinator.remove(store) }

            let metadata = coordinator.metadata(for: store)
            guard let currentStoreUUID = metadata[NSStoreUUIDKey] as? String,
                  !currentStoreUUID.isEmpty,
                  previousStoreUUID == nil || currentStoreUUID != previousStoreUUID
            else {
                throw PersistentStoreTransitionError.transitionFailed(
                    "Core Data retained the destroyed staging-store identity."
                )
            }

            let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
            try context.performAndWait {
                defer { context.reset() }
                for entity in model.entities where !entity.isAbstract {
                    guard let entityName = entity.name else {
                        throw PersistentStoreTransitionError.transitionFailed(
                            "The current Core Data model contains an unnamed entity."
                        )
                    }
                    let request = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
                    request.includesSubentities = false
                    guard try context.count(for: request) == 0 else {
                        throw PersistentStoreTransitionError.transitionFailed(
                            "Core Data retained records after staging-store destruction."
                        )
                    }
                }
            }
        }
    }

    private static var sqliteStoreOptions: [AnyHashable: Any] {
        [
            NSMigratePersistentStoresAutomaticallyOption: true as NSNumber,
            NSInferMappingModelAutomaticallyOption: true as NSNumber,
            NSPersistentHistoryTrackingKey: true as NSNumber,
            NSPersistentStoreRemoteChangeNotificationPostOptionKey: true as NSNumber,
            NSPersistentStoreFileProtectionKey: protectionClass
        ]
    }

    private static func hasRequiredLocalOptions(_ options: [AnyHashable: Any]) -> Bool {
        (options[NSPersistentHistoryTrackingKey] as? NSNumber)?.boolValue == true
            && (options[NSPersistentStoreRemoteChangeNotificationPostOptionKey] as? NSNumber)?.boolValue == true
            && (options[NSPersistentStoreFileProtectionKey] as? String) == protectionClass
    }

    private static func shouldUseCloud(cloudSyncEnabled: Bool?) -> Bool {
        if let cloudSyncEnabled {
            return cloudSyncEnabled
        }
        #if HOURLEAF_LOCAL_DEVICE || targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }

    private static func defaultStoreURL() -> URL? {
        NSPersistentCloudKitContainer(name: modelName).persistentStoreDescriptions.first?.url
    }

    private static func makeContainer(
        descriptor: PersistentStoreDescriptor
    ) -> (container: NSPersistentCloudKitContainer, error: PersistenceStartupError?) {
        let container = NSPersistentCloudKitContainer(name: modelName)
        var result: PersistenceStartupError?

        guard let description = container.persistentStoreDescriptions.first else {
            result = .missingStoreDescription
            configureViewContext(container.viewContext)
            return (container, result)
        }

        switch descriptor.mode {
        case .inMemory:
            description.type = NSInMemoryStoreType
            description.url = nil
            description.cloudKitContainerOptions = nil
        case .localOnlySQLite:
            description.type = NSSQLiteStoreType
            description.url = descriptor.url
            description.cloudKitContainerOptions = nil
        case .privateCloudSQLite:
            description.type = NSSQLiteStoreType
            description.url = descriptor.url
            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: cloudContainerIdentifier
            )
        }

        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        description.setOption(protectionClass as NSString, forKey: NSPersistentStoreFileProtectionKey)
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        description.shouldAddStoreAsynchronously = false

        var loadFailure: Error?
        container.loadPersistentStores { _, error in
            loadFailure = error
        }
        if let loadFailure {
            result = .loadFailed(loadFailure.localizedDescription)
        }
        configureViewContext(container.viewContext)
        return (container, result)
    }

    private static func configureViewContext(_ context: NSManagedObjectContext) {
        context.automaticallyMergesChangesFromParent = true
        context.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
        context.undoManager = nil
    }
}
