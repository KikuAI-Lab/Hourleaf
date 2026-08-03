import CryptoKit
import Foundation

enum ReportFingerprint {
    static func calculation(
        report: MonthlyReport,
        entries: [TimeEntry],
        settings: AppSettings,
        policies: [ReportingPolicy]
    ) -> String {
        calculationV1(
            report: report,
            entries: entries,
            settings: settings,
            policies: policies
        )
    }

    static func calculationV1(
        report: MonthlyReport,
        entries: [TimeEntry],
        settings: AppSettings,
        policies: [ReportingPolicy]
    ) -> String {
        var fields = [
            "month=\(report.month.key)",
            "ledgerStart=\(settings.ledgerStartMonth.key)",
            "openingServiceCarry=\(settings.openingServiceCarryMinutes)",
            "openingCreditCarry=\(settings.openingCreditCarryMinutes)",
            "rawService=\(report.rawServiceMinutes)",
            "rawCredit=\(report.rawCreditMinutes)",
            "serviceCarryIn=\(report.serviceCarryIn)",
            "creditCarryIn=\(report.creditCarryIn)",
            "serviceHours=\(report.serviceHours)",
            "creditHours=\(report.creditHours)",
            "serviceCarryOut=\(report.serviceCarryOut)",
            "creditCarryOut=\(report.creditCarryOut)"
        ]

        let relevantEntries = entries
            .filter {
                $0.day.monthKey >= settings.ledgerStartMonth
                    && $0.day.monthKey <= report.month
            }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        fields.append(contentsOf: relevantEntries.map {
            "entry=\($0.id.uuidString.lowercased())|\($0.kind.rawValue)|\($0.day.key)|\($0.minutes)"
        })

        let relevantPolicies = policies
            .filter { $0.effectiveMonth <= report.month }
            .sorted {
                ($0.effectiveMonth, $0.createdAt, $0.id.uuidString)
                    < ($1.effectiveMonth, $1.createdAt, $1.id.uuidString)
            }
        fields.append(contentsOf: relevantPolicies.map {
            let milliseconds = Int64(($0.createdAt.timeIntervalSince1970 * 1_000).rounded())
            return "policy=\($0.id.uuidString.lowercased())|\($0.effectiveMonth.key)|\($0.mode.rawValue)|\(milliseconds)"
        })

        return digest(fields.joined(separator: "\n"))
    }

    static func calculationV2(
        report: MonthlyReport,
        entries: [TimeEntry],
        mode: RemainderMode
    ) -> String {
        var fields = [
            "hourleaf-report-calculation-v2",
            "month=\(report.month.key)",
            "rawService=\(report.rawServiceMinutes)",
            "rawCredit=\(report.rawCreditMinutes)",
            "serviceCarryIn=\(report.serviceCarryIn)",
            "creditCarryIn=\(report.creditCarryIn)",
            "serviceHours=\(report.serviceHours)",
            "creditHours=\(report.creditHours)",
            "serviceCarryOut=\(report.serviceCarryOut)",
            "creditCarryOut=\(report.creditCarryOut)",
            "mode=\(mode.rawValue)"
        ]

        let relevantEntries = entries
            .filter { $0.day.monthKey == report.month }
            .sorted { $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased() }
        fields.append(contentsOf: relevantEntries.map {
            "entry=\($0.id.uuidString.lowercased())|\($0.kind.rawValue)|\($0.day.key)|\($0.minutes)"
        })

        return "v2:\(digest(fields.joined(separator: "\n")))"
    }

    static func presentation(
        calculationFingerprint: String,
        language: ReportLanguage,
        creditLabel: String,
        templateID: String,
        text: String
    ) -> String {
        if calculationFingerprint.hasPrefix("v2:") {
            return presentationV2(
                calculationFingerprint: calculationFingerprint,
                templateID: templateID,
                text: text
            )
        }
        return presentationV1(
            calculationFingerprint: calculationFingerprint,
            language: language,
            creditLabel: creditLabel,
            templateID: templateID,
            text: text
        )
    }

    static func presentationV1(
        calculationFingerprint: String,
        language: ReportLanguage,
        creditLabel: String,
        templateID: String,
        text: String
    ) -> String {
        let fields = [
            "calculation=\(calculationFingerprint)",
            "language=\(language.rawValue)",
            "creditLabel=\(encoded(creditLabel))",
            "template=\(templateID)",
            "text=\(encoded(text))"
        ]
        return digest(fields.joined(separator: "\n"))
    }

    static func presentationV2(
        calculationFingerprint: String,
        templateID: String,
        text: String
    ) -> String {
        let fields = [
            "hourleaf-report-presentation-v2",
            "calculation=\(calculationFingerprint)",
            "template=\(templateID)",
            "text=\(encoded(text))"
        ]
        return "v2:\(digest(fields.joined(separator: "\n")))"
    }

    fileprivate static func encoded(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }

    fileprivate static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum ServiceYearFingerprint {
    static func calculation(
        startMonth: MonthKey,
        endMonth: MonthKey,
        actualServiceMinutes: Int,
        baselineServiceMinutes: Int,
        targetMinutes: Int,
        entries: [TimeEntry]
    ) -> String {
        var fields = [
            "hourleaf-service-year-archive-v1",
            "start=\(startMonth.key)",
            "end=\(endMonth.key)",
            "actualService=\(actualServiceMinutes)",
            "baselineService=\(baselineServiceMinutes)",
            "target=\(targetMinutes)"
        ]

        let endExclusiveMonth = endMonth.advanced(by: 1, calendar: .hourleaf)
        let relevantEntries = entries
            .filter {
                $0.kind == .service
                    && $0.day.monthKey >= startMonth
                    && $0.day.monthKey < endExclusiveMonth
            }
            .sorted { $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased() }
        fields.append(contentsOf: relevantEntries.map {
            "entry=\($0.id.uuidString.lowercased())|\($0.day.key)|\($0.minutes)"
        })

        return "service-year-v1:\(ReportFingerprint.digest(fields.joined(separator: "\n")))"
    }
}
