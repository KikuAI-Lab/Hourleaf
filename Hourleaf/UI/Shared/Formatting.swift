import Foundation

enum DurationText {
    static func format(minutes: Int) -> String {
        let safe = max(0, minutes)
        let hours = safe / 60
        let remainder = safe % 60
        if hours == 0 { return String(format: String(localized: "duration.minutes_format"), remainder) }
        if remainder == 0 { return String(format: String(localized: "duration.hours_format"), hours) }
        return String(format: String(localized: "duration.hours_minutes_format"), hours, remainder)
    }
}
extension EntryKind {
    var localizedName: String {
        switch self {
        case .service: String(localized: "entry.kind.service")
        case .credit: String(localized: "entry.kind.credit")
        }
    }

    var systemImage: String {
        switch self {
        case .service: "leaf.fill"
        case .credit: "sparkles"
        }
    }
}

extension RemainderMode {
    var localizedName: String {
        switch self {
        case .carry: String(localized: "policy.carry")
        case .roundNearest: String(localized: "policy.round")
        case .discard: String(localized: "policy.discard")
        }
    }
}

extension ReportLanguage {
    var localizedName: String {
        switch self {
        case .english: String(localized: "language.english")
        case .russian: String(localized: "language.russian")
        case .ukrainian: String(localized: "language.ukrainian")
        }
    }
}

enum AppDateText {
    static func month(_ month: MonthKey) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("LLLL yyyy")
        let raw = formatter.string(from: month.date(calendar: .hourleaf))
        return raw.prefix(1).uppercased(with: .current) + raw.dropFirst()
    }

    static func day(_ day: LocalDay) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        return formatter.string(from: day.date(calendar: .hourleaf))
    }

    static func range(from start: LocalDay, through end: LocalDay) -> String {
        let formatter = DateIntervalFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(
            from: start.date(calendar: .hourleaf),
            to: end.date(calendar: .hourleaf)
        )
    }

    static func weekday(_ value: Int) -> String {
        let symbols = Calendar.hourleaf.weekdaySymbols
        guard symbols.indices.contains(value - 1) else { return "" }
        return symbols[value - 1].capitalized(with: .current)
    }
}
