import CoreData
import Foundation

@MainActor
protocol LedgerRepository: AnyObject {
    func fetchEntries() throws -> [TimeEntry]
    func saveEntry(_ entry: TimeEntry) throws
    func deleteEntry(id: UUID) throws
    func loadSettings() throws -> AppSettings
    func saveSettings(_ settings: AppSettings) throws
    func fetchPolicies() throws -> [ReportingPolicy]
    func savePolicy(_ policy: ReportingPolicy) throws
    func fetchReminders() throws -> [ReminderSchedule]
    func saveReminder(_ reminder: ReminderSchedule) throws
    func deleteReminder(id: UUID) throws
    func fetchReceipts() throws -> [ReportReceipt]
    func saveReceipt(_ receipt: ReportReceipt) throws
}

@MainActor
final class CoreDataLedgerRepository: LedgerRepository {
    private static let settingsID = UUID(uuidString: "4E777EA2-6E2E-4C02-AC50-734F6F8B91E1")!
    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    func fetchEntries() throws -> [TimeEntry] {
        let request: NSFetchRequest<EntryEntity> = EntryEntity.request()
        request.sortDescriptors = [NSSortDescriptor(key: "localDay", ascending: false)]
        return try context.fetch(request).compactMap(Self.domainEntry)
    }

    func saveEntry(_ entry: TimeEntry) throws {
        let request: NSFetchRequest<EntryEntity> = EntryEntity.request()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", entry.id as CVarArg)
        let object = try context.fetch(request).first ?? context.insert(EntryEntity.self)
        object.id = entry.id
        object.kind = entry.kind.rawValue
        object.localDay = entry.day.key
        object.minutes = Int32(entry.minutes)
        object.note = entry.note
        object.createdAt = entry.createdAt
        object.updatedAt = entry.updatedAt
        try saveIfNeeded()
    }

    func deleteEntry(id: UUID) throws {
        let request: NSFetchRequest<EntryEntity> = EntryEntity.request()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        try context.fetch(request).forEach(context.delete)
        try saveIfNeeded()
    }

    func loadSettings() throws -> AppSettings {
        let request: NSFetchRequest<SettingsEntity> = SettingsEntity.request()
        let objects = try context.fetch(request)
        guard let object = preferredSettingsObject(in: objects) else {
            let settings = AppSettings()
            try saveSettings(settings)
            return settings
        }
        if objects.count > 1 {
            objects.filter { $0 !== object }.forEach(context.delete)
            try saveIfNeeded()
        }
        return AppSettings(
            reportLanguage: object.reportLanguage.flatMap(ReportLanguage.init(rawValue:))
                ?? .preferredForCurrentLocale,
            creditLabelEnglish: object.creditLabelEnglish ?? "Credit hours",
            creditLabelRussian: object.creditLabelRussian ?? "Кредит часов",
            creditLabelUkrainian: object.creditLabelUkrainian ?? "Кредит годин",
            ledgerStartMonth: MonthKey(key: object.ledgerStartMonth ?? "") ?? MonthKey(Date(), calendar: .hourleaf),
            baselineServiceYearMinutes: Int(object.baselineServiceYearMinutes),
            baselineServiceYearStart: MonthKey(key: object.baselineServiceYearStart ?? "")
                ?? ServiceYearCalculator.serviceYearStart(containing: LocalDay(Date(), calendar: .hourleaf)).monthKey,
            openingServiceCarryMinutes: Int(object.openingServiceCarryMinutes),
            openingCreditCarryMinutes: Int(object.openingCreditCarryMinutes),
            onboardingComplete: object.onboardingComplete
        )
    }

    func saveSettings(_ settings: AppSettings) throws {
        let request: NSFetchRequest<SettingsEntity> = SettingsEntity.request()
        let objects = try context.fetch(request)
        let object = preferredSettingsObject(in: objects) ?? context.insert(SettingsEntity.self)
        object.id = Self.settingsID
        object.reportLanguage = settings.reportLanguage.rawValue
        object.creditLabelEnglish = settings.creditLabelEnglish
        object.creditLabelRussian = settings.creditLabelRussian
        object.creditLabelUkrainian = settings.creditLabelUkrainian
        object.ledgerStartMonth = settings.ledgerStartMonth.key
        object.baselineServiceYearMinutes = Int64(settings.baselineServiceYearMinutes)
        object.baselineServiceYearStart = settings.baselineServiceYearStart.key
        object.openingServiceCarryMinutes = Int32(settings.openingServiceCarryMinutes)
        object.openingCreditCarryMinutes = Int32(settings.openingCreditCarryMinutes)
        object.onboardingComplete = settings.onboardingComplete
        object.updatedAt = .now
        objects.filter { $0 !== object }.forEach(context.delete)
        try saveIfNeeded()
    }

    func fetchPolicies() throws -> [ReportingPolicy] {
        let request: NSFetchRequest<PolicyRevisionEntity> = PolicyRevisionEntity.request()
        return try context.fetch(request).compactMap { object in
            guard
                let month = object.effectiveMonth.flatMap(MonthKey.init(key:)),
                let mode = object.mode.flatMap(RemainderMode.init(rawValue:))
            else { return nil }
            return ReportingPolicy(
                id: object.id ?? UUID(),
                effectiveMonth: month,
                mode: mode,
                carryAcrossServiceYear: object.carryAcrossServiceYear,
                createdAt: object.createdAt ?? .distantPast
            )
        }
    }

    func savePolicy(_ policy: ReportingPolicy) throws {
        let request: NSFetchRequest<PolicyRevisionEntity> = PolicyRevisionEntity.request()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", policy.id as CVarArg)
        let object = try context.fetch(request).first ?? context.insert(PolicyRevisionEntity.self)
        object.id = policy.id
        object.effectiveMonth = policy.effectiveMonth.key
        object.mode = policy.mode.rawValue
        object.carryAcrossServiceYear = policy.carryAcrossServiceYear
        object.createdAt = policy.createdAt
        try saveIfNeeded()
    }

    func fetchReminders() throws -> [ReminderSchedule] {
        let request: NSFetchRequest<ReminderEntity> = ReminderEntity.request()
        return try context.fetch(request).compactMap { object in
            guard let id = object.id else { return nil }
            return ReminderSchedule(
                id: id,
                weekday: Int(object.weekday),
                hour: Int(object.hour),
                minute: Int(object.minute),
                isEnabled: object.isEnabled
            )
        }.sorted { ($0.weekday, $0.hour, $0.minute) < ($1.weekday, $1.hour, $1.minute) }
    }

    func saveReminder(_ reminder: ReminderSchedule) throws {
        let request: NSFetchRequest<ReminderEntity> = ReminderEntity.request()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", reminder.id as CVarArg)
        let object = try context.fetch(request).first ?? context.insert(ReminderEntity.self)
        object.id = reminder.id
        object.weekday = Int16(reminder.weekday)
        object.hour = Int16(reminder.hour)
        object.minute = Int16(reminder.minute)
        object.isEnabled = reminder.isEnabled
        try saveIfNeeded()
    }

    func deleteReminder(id: UUID) throws {
        let request: NSFetchRequest<ReminderEntity> = ReminderEntity.request()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        try context.fetch(request).forEach(context.delete)
        try saveIfNeeded()
    }

    func fetchReceipts() throws -> [ReportReceipt] {
        let request: NSFetchRequest<ReportReceiptEntity> = ReportReceiptEntity.request()
        request.sortDescriptors = [NSSortDescriptor(key: "preparedAt", ascending: false)]
        return try context.fetch(request).compactMap { object in
            guard
                let id = object.id,
                let month = object.monthKey.flatMap(MonthKey.init(key:)),
                let text = object.reportText,
                let preparedAt = object.preparedAt
            else { return nil }
            return ReportReceipt(
                id: id,
                month: month,
                text: text,
                serviceHours: Int(object.serviceHours),
                creditHours: Int(object.creditHours),
                serviceCarryOut: Int(object.serviceCarryOut),
                creditCarryOut: Int(object.creditCarryOut),
                preparedAt: preparedAt,
                confirmedSentAt: object.confirmedSentAt
            )
        }
    }

    func saveReceipt(_ receipt: ReportReceipt) throws {
        let request: NSFetchRequest<ReportReceiptEntity> = ReportReceiptEntity.request()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", receipt.id as CVarArg)
        let object = try context.fetch(request).first ?? context.insert(ReportReceiptEntity.self)
        object.id = receipt.id
        object.monthKey = receipt.month.key
        object.reportText = receipt.text
        object.serviceHours = Int32(receipt.serviceHours)
        object.creditHours = Int32(receipt.creditHours)
        object.serviceCarryOut = Int32(receipt.serviceCarryOut)
        object.creditCarryOut = Int32(receipt.creditCarryOut)
        object.preparedAt = receipt.preparedAt
        object.confirmedSentAt = receipt.confirmedSentAt
        try saveIfNeeded()
    }

    private func saveIfNeeded() throws {
        if context.hasChanges { try context.save() }
    }

    private func preferredSettingsObject(in objects: [SettingsEntity]) -> SettingsEntity? {
        objects.max { lhs, rhs in
            if lhs.onboardingComplete != rhs.onboardingComplete {
                return !lhs.onboardingComplete && rhs.onboardingComplete
            }
            return (lhs.updatedAt ?? .distantPast) < (rhs.updatedAt ?? .distantPast)
        }
    }

    private static func domainEntry(_ object: EntryEntity) -> TimeEntry? {
        guard
            let id = object.id,
            let kind = object.kind.flatMap(EntryKind.init(rawValue:)),
            let day = object.localDay.flatMap(LocalDay.init(key:))
        else { return nil }
        return TimeEntry(
            id: id,
            kind: kind,
            day: day,
            minutes: Int(object.minutes),
            note: object.note,
            createdAt: object.createdAt ?? .distantPast,
            updatedAt: object.updatedAt ?? .distantPast
        )
    }
}
