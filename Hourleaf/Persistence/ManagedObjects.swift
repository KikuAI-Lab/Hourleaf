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
