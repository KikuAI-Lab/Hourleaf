import CryptoKit
import Foundation

enum ReportFingerprint {
    static func calculation(
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

    static func presentation(
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

    private static func encoded(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
