import Foundation

struct LocalDay: Hashable, Codable, Comparable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(_ date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    init?(key: String) {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        self.init(year: parts[0], month: parts[1], day: parts[2])
    }

    var key: String { String(format: "%04d-%02d-%02d", year, month, day) }
    var monthKey: MonthKey { MonthKey(year: year, month: month) }

    func date(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? .distantPast
    }

    static func < (lhs: LocalDay, rhs: LocalDay) -> Bool { lhs.key < rhs.key }
}
struct MonthKey: Hashable, Codable, Comparable, Sendable {
    let year: Int
    let month: Int

    init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    init(_ date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1)
    }

    init?(key: String) {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        self.init(year: parts[0], month: parts[1])
    }

    var key: String { String(format: "%04d-%02d", year, month) }

    func date(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: 1, hour: 12)) ?? .distantPast
    }

    func advanced(by value: Int, calendar: Calendar = .current) -> MonthKey {
        MonthKey(calendar.date(byAdding: .month, value: value, to: date(calendar: calendar)) ?? date(calendar: calendar), calendar: calendar)
    }

    static func < (lhs: MonthKey, rhs: MonthKey) -> Bool { lhs.key < rhs.key }
}

extension Calendar {
    static var hourleaf: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .current
        return calendar
    }
}
