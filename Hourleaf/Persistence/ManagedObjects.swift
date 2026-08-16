import CoreData
import Foundation

@objc(EntryEntity)
final class EntryEntity: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var kind: String?
    @NSManaged var localDay: String?
    @NSManaged var minutes: Int32
    @NSManaged var note: String?
    @NSManaged var createdAt: Date?
    @NSManaged var updatedAt: Date?
    @NSManaged var deletedAt: Date?
    @NSManaged var source: String?
    @NSManaged var revision: Int64
    @NSManaged var lastMutationID: UUID?
}

@objc(EntryRevisionEntity)
final class EntryRevisionEntity: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var entryID: UUID?
    @NSManaged var mutationID: UUID?
    @NSManaged var parentMutationID: UUID?
    @NSManaged var revertedMutationID: UUID?
    @NSManaged var revision: Int64
    @NSManaged var operation: String?
    @NSManaged var kind: String?
    @NSManaged var localDay: String?
    @NSManaged var minutes: Int32
    @NSManaged var note: String?
    @NSManaged var entryCreatedAt: Date?
    @NSManaged var entryUpdatedAt: Date?
    @NSManaged var entryDeletedAt: Date?
    @NSManaged var source: String?
    @NSManaged var occurredAt: Date?
}

@objc(PolicyRevisionEntity)
final class PolicyRevisionEntity: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var effectiveMonth: String?
    @NSManaged var mode: String?
    @NSManaged var carryAcrossServiceYear: Bool
    @NSManaged var createdAt: Date?
}

@objc(ReminderEntity)
final class ReminderEntity: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var weekday: Int16
    @NSManaged var hour: Int16
    @NSManaged var minute: Int16
    @NSManaged var isEnabled: Bool
    @NSManaged var createdAt: Date?
    @NSManaged var updatedAt: Date?
}

@objc(ReportReceiptEntity)
final class ReportReceiptEntity: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var monthKey: String?
    @NSManaged var reportText: String?
    @NSManaged var serviceHours: Int32
    @NSManaged var creditHours: Int32
    @NSManaged var serviceCarryOut: Int32
    @NSManaged var creditCarryOut: Int32
    @NSManaged var preparedAt: Date?
    @NSManaged var confirmedSentAt: Date?
    @NSManaged var schemaVersion: Int16
    @NSManaged var version: Int32
    @NSManaged var supersedesID: UUID?
    @NSManaged var rawServiceMinutes: Int64
    @NSManaged var rawCreditMinutes: Int64
    @NSManaged var serviceCarryIn: Int32
    @NSManaged var creditCarryIn: Int32
    @NSManaged var reportingMode: String?
    @NSManaged var reportLanguage: String?
    @NSManaged var creditLabel: String?
    @NSManaged var templateID: String?
    @NSManaged var calculationFingerprint: String?
    @NSManaged var presentationFingerprint: String?
    @NSManaged var createdBySource: String?
    @NSManaged var legacyCalculationUnavailable: Bool
}

@objc(ReportStateEntity)
final class ReportStateEntity: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var monthKey: String?
    @NSManaged var state: String?
    @NSManaged var lastStableState: String?
    @NSManaged var currentSnapshotID: UUID?
    @NSManaged var reviewedCalculationFingerprint: String?
    @NSManaged var reviewedPresentationFingerprint: String?
    @NSManaged var bibleStudyCount: Int16
    @NSManaged var updatedAt: Date?
    @NSManaged var changedAt: Date?
}

@objc(ServiceYearArchiveEntity)
final class ServiceYearArchiveEntity: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var startMonthKey: String?
    @NSManaged var endMonthKey: String?
    @NSManaged var actualServiceMinutes: Int64
    @NSManaged var baselineServiceMinutes: Int64
    @NSManaged var targetMinutes: Int64
    @NSManaged var calculationFingerprint: String?
    @NSManaged var version: Int32
    @NSManaged var supersedesID: UUID?
    @NSManaged var createdAt: Date?
}

@objc(SettingsEntity)
final class SettingsEntity: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var reportLanguage: String?
    @NSManaged var creditLabelEnglish: String?
    @NSManaged var creditLabelRussian: String?
    @NSManaged var creditLabelUkrainian: String?
    @NSManaged var ledgerStartMonth: String?
    @NSManaged var baselineServiceYearMinutes: Int64
    @NSManaged var baselineServiceYearStart: String?
    @NSManaged var openingServiceCarryMinutes: Int32
    @NSManaged var openingCreditCarryMinutes: Int32
    @NSManaged var onboardingComplete: Bool
    @NSManaged var updatedAt: Date?
    @NSManaged var dataRevision: Int16
    @NSManaged var planningVisible: Bool
    @NSManaged var quietGapCheckEnabled: Bool
    @NSManaged var quietGapDays: Int16
    @NSManaged var timerVisible: Bool
    @NSManaged var syncMode: String?
    @NSManaged var widgetPrivacyMode: String?
    @NSManaged var lastPurgeAt: Date?
}

@objc(PresetEntity)
final class PresetEntity: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var kind: String?
    @NSManaged var minutes: Int32
    @NSManaged var position: Int16
    @NSManaged var createdAt: Date?
    @NSManaged var updatedAt: Date?
    @NSManaged var deletedAt: Date?
}

@objc(DayAcknowledgementEntity)
final class DayAcknowledgementEntity: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var localDay: String?
    @NSManaged var status: String?
    @NSManaged var source: String?
    @NSManaged var createdAt: Date?
    @NSManaged var updatedAt: Date?
}

extension NSManagedObject {
    static func request<T: NSManagedObject>() -> NSFetchRequest<T> {
        NSFetchRequest<T>(entityName: String(describing: T.self))
    }
}

extension NSManagedObjectContext {
    func insert<T: NSManagedObject>(_ type: T.Type) -> T {
        guard let object = NSEntityDescription.insertNewObject(
            forEntityName: String(describing: type),
            into: self
        ) as? T else {
            preconditionFailure("Core Data model is missing \(String(describing: type))")
        }
        return object
    }
}
