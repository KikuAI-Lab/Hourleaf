import Foundation

enum ReportFormatter {
    static func format(_ report: MonthlyReport, settings: AppSettings) -> String {
        let language = settings.reportLanguage
        var lines = [
            monthTitle(report.month, language: language),
            "\(hoursLabel(language)): \(report.serviceHours)"
        ]
        if report.creditHours > 0 {
            lines.append("\(settings.creditLabel(for: language)): \(report.creditHours)")
        }
        if report.bibleStudyCount > 0 {
            lines.append("\(bibleStudiesLabel(language)): \(report.bibleStudyCount)")
        }
        return lines.joined(separator: "\n")
    }

    static func monthTitle(_ month: MonthKey, language: ReportLanguage) -> String {
        let locale = Locale(identifier: localeIdentifier(language))
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "LLLL yyyy"
        let raw = formatter.string(from: month.date(calendar: .hourleaf))
        guard let first = raw.first else { return raw }
        return String(first).uppercased(with: locale) + raw.dropFirst()
    }

    private static func hoursLabel(_ language: ReportLanguage) -> String {
        switch language {
        case .english: "Hours"
        case .russian: "Часы"
        case .ukrainian: "Години"
        }
    }

    private static func bibleStudiesLabel(_ language: ReportLanguage) -> String {
        switch language {
        case .english: "Bible studies"
        case .russian: "Изучения Библии"
        case .ukrainian: "Вивчення Біблії"
        }
    }

    private static func localeIdentifier(_ language: ReportLanguage) -> String {
        switch language {
        case .english: "en_US"
        case .russian: "ru_RU"
        case .ukrainian: "uk_UA"
        }
    }
}
