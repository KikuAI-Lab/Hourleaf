import Foundation

enum EntryKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case service
    case credit

    var id: String { rawValue }
}

struct TimeEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    var kind: EntryKind
    var day: LocalDay
    var minutes: Int
    var note: String?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        kind: EntryKind,
        day: LocalDay,
        minutes: Int,
        note: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.day = day
        self.minutes = minutes
        self.note = note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum RemainderMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case carry
    case roundNearest
    case discard

    var id: String { rawValue }
}

struct ReportingPolicy: Identifiable, Equatable, Sendable {
    let id: UUID
    var effectiveMonth: MonthKey
    var mode: RemainderMode
    let createdAt: Date

    init(
        id: UUID = UUID(),
        effectiveMonth: MonthKey,
        mode: RemainderMode = .carry,
        createdAt: Date = .now
    ) {
        self.id = id
        self.effectiveMonth = effectiveMonth
        self.mode = mode
        self.createdAt = createdAt
    }
}

struct GoalPolicy: Equatable, Sendable {
    static let regularPioneer = GoalPolicy(targetMinutes: 600 * 60, startMonth: 9)

    let targetMinutes: Int
    let startMonth: Int
}

struct ReminderSchedule: Identifiable, Equatable, Sendable {
    let id: UUID
    var weekday: Int
    var hour: Int
    var minute: Int
    var isEnabled: Bool

    init(id: UUID = UUID(), weekday: Int, hour: Int, minute: Int, isEnabled: Bool = true) {
        self.id = id
        self.weekday = weekday
        self.hour = hour
        self.minute = minute
        self.isEnabled = isEnabled
    }
}

struct AppSettings: Equatable, Sendable {
    var reportLanguage: ReportLanguage = .preferredForCurrentLocale
    var creditLabelEnglish = "Credit hours"
    var creditLabelRussian = "Кредит часов"
    var creditLabelUkrainian = "Кредит годин"
    var ledgerStartMonth = MonthKey(Date(), calendar: .hourleaf)
    var baselineServiceYearMinutes = 0
    var baselineServiceYearStart = AppSettings.currentServiceYearStart
    var openingServiceCarryMinutes = 0
    var openingCreditCarryMinutes = 0
    var onboardingComplete = false

    func creditLabel(for language: ReportLanguage) -> String {
        switch language {
        case .english: creditLabelEnglish
        case .russian: creditLabelRussian
        case .ukrainian: creditLabelUkrainian
        }
    }

    private static var currentServiceYearStart: MonthKey {
        ServiceYearCalculator.serviceYearStart(
            containing: LocalDay(Date(), calendar: .hourleaf)
        ).monthKey
    }
}

struct LedgerEntryRecord: Identifiable, Equatable, Sendable {
    let entry: TimeEntry
    let deletedAt: Date?
    let source: String?
    let revision: Int64
    let lastMutationID: UUID?

    var id: UUID { entry.id }
    var isDeleted: Bool { deletedAt != nil }
}

struct EntryRevisionRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    let entryID: UUID
    let mutationID: UUID
    let parentMutationID: UUID?
    let revertedMutationID: UUID?
    let revision: Int64
    let operation: String
    let kind: String
    let localDay: String
    let minutes: Int
    let note: String?
    let entryCreatedAt: Date
    let entryUpdatedAt: Date
    let entryDeletedAt: Date?
    let source: String
    let occurredAt: Date
}

struct ReminderRecord: Identifiable, Equatable, Sendable {
    let reminder: ReminderSchedule
    let createdAt: Date?
    let updatedAt: Date?

    var id: UUID { reminder.id }
}

struct ReportSnapshotMetadata: Identifiable, Equatable, Sendable {
    let receipt: ReportReceipt
    let schemaVersion: Int
    let version: Int
    let supersedesID: UUID?
    let rawServiceMinutes: Int
    let rawCreditMinutes: Int
    let serviceCarryIn: Int
    let creditCarryIn: Int
    let reportingMode: String?
    let reportLanguage: String?
    let creditLabel: String?
    let templateID: String?
    let calculationFingerprint: String?
    let presentationFingerprint: String?
    let createdBySource: String?
    let legacyCalculationUnavailable: Bool

    var id: UUID { receipt.id }
}

struct ReportSnapshotDetails: Equatable, Sendable {
    let report: MonthlyReport
    let reportingMode: RemainderMode
    let reportLanguage: ReportLanguage
    let creditLabel: String
    let templateID: String
    let calculationFingerprint: String
    let presentationFingerprint: String
}

struct ReportStateRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    let month: MonthKey
    let state: String
    let lastStableState: String?
    let currentSnapshotID: UUID?
    let reviewedCalculationFingerprint: String?
    let reviewedPresentationFingerprint: String?
    let updatedAt: Date
    let changedAt: Date?
}

struct PresetRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: EntryKind
    let minutes: Int
    let position: Int
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?
}

struct DayAcknowledgementRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    let day: LocalDay
    let status: String
    let source: String
    let createdAt: Date
    let updatedAt: Date
}

struct ServiceYearArchiveRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    let startMonth: MonthKey
    let endMonth: MonthKey
    let actualServiceMinutes: Int
    let baselineServiceMinutes: Int
    let targetMinutes: Int
    let calculationFingerprint: String
    let version: Int
    let supersedesID: UUID?
    let createdAt: Date
}

struct LedgerSettingsMetadata: Equatable, Sendable {
    let id: UUID
    let dataRevision: Int
    let planningVisible: Bool
    let quietGapCheckEnabled: Bool
    let quietGapDays: Int
    let timerVisible: Bool
    let syncMode: String
    let widgetPrivacyMode: String
    let lastPurgeAt: Date?
}

struct LedgerSnapshot: Equatable, Sendable {
    let entries: [LedgerEntryRecord]
    let settings: AppSettings
    let settingsMetadata: LedgerSettingsMetadata
    let policies: [ReportingPolicy]
    let reminders: [ReminderRecord]
    let reportSnapshots: [ReportSnapshotMetadata]
    let reportStates: [ReportStateRecord]
    let entryRevisions: [EntryRevisionRecord]
    let presets: [PresetRecord]
    let dayAcknowledgements: [DayAcknowledgementRecord]
    let serviceYearArchives: [ServiceYearArchiveRecord]

    var activeEntries: [TimeEntry] {
        entries.filter { !$0.isDeleted }.map(\.entry)
    }

    var deletedEntries: [LedgerEntryRecord] {
        entries.filter(\.isDeleted)
    }

    var reminderSchedules: [ReminderSchedule] {
        reminders.map(\.reminder)
    }

    var receipts: [ReportReceipt] {
        reportSnapshots.map(\.receipt)
    }
}

enum ReportLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case russian = "ru"
    case ukrainian = "uk"

    var id: String { rawValue }

    static var preferredForCurrentLocale: ReportLanguage {
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        if preferred.hasPrefix("ru") { return .russian }
        if preferred.hasPrefix("uk") { return .ukrainian }
        return .english
    }
}

struct MonthlyReport: Identifiable, Equatable, Sendable {
    var id: String { month.key }
    let month: MonthKey
    let rawServiceMinutes: Int
    let rawCreditMinutes: Int
    let serviceCarryIn: Int
    let creditCarryIn: Int
    let serviceHours: Int
    let creditHours: Int
    let serviceCarryOut: Int
    let creditCarryOut: Int
}

struct ReportReceipt: Identifiable, Equatable, Sendable {
    let id: UUID
    let month: MonthKey
    let text: String
    let serviceHours: Int
    let creditHours: Int
    let serviceCarryOut: Int
    let creditCarryOut: Int
    let preparedAt: Date
    var confirmedSentAt: Date?
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
