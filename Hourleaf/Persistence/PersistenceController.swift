import CoreData
import Foundation

@MainActor
final class PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentCloudKitContainer

    init(inMemory: Bool = false, cloudSyncEnabled: Bool? = nil) {
        container = NSPersistentCloudKitContainer(name: "HourleafModel")
        guard let description = container.persistentStoreDescriptions.first else {
            preconditionFailure("Hourleaf persistent store description is missing")
        }

        let shouldUseCloud: Bool
        if let cloudSyncEnabled {
            shouldUseCloud = cloudSyncEnabled && !inMemory
        } else {
            #if HOURLEAF_LOCAL_DEVICE || targetEnvironment(simulator)
            shouldUseCloud = false
            #else
            shouldUseCloud = !inMemory
            #endif
        }

        if inMemory {
            description.url = URL(fileURLWithPath: "/dev/null")
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

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError {
            preconditionFailure("Unable to load Hourleaf data: \(loadError.localizedDescription)")
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
        container.viewContext.undoManager = nil
    }
}
