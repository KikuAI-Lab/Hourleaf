@preconcurrency import CoreData
import Foundation

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

final class PersistenceController: @unchecked Sendable {
    static let shared = PersistenceController()

    let container: NSPersistentCloudKitContainer
    let startupError: PersistenceStartupError?

    init(
        inMemory: Bool = false,
        cloudSyncEnabled: Bool = false,
        storeURL: URL? = nil
    ) {
        container = NSPersistentCloudKitContainer(name: "HourleafModel")
        var result: PersistenceStartupError?

        if let description = container.persistentStoreDescriptions.first {
            // Local storage is the truthful default for every build. A future
            // iCloud slice must pass an explicit opt-in after migration gates.
            let shouldUseCloud = cloudSyncEnabled && !inMemory

            if inMemory {
                description.type = NSInMemoryStoreType
                description.url = nil
            } else if let storeURL {
                description.url = storeURL
            }
            if shouldUseCloud {
                description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                    containerIdentifier: "iCloud.com.kikuai.hourleaf"
                )
            } else {
                description.cloudKitContainerOptions = nil
            }
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
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
        } else {
            result = .missingStoreDescription
        }

        startupError = result
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
        container.viewContext.undoManager = nil
    }
}
