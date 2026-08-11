import Foundation

enum WatchTimeEntryKindV1: String, Codable, CaseIterable, Sendable {
    case service
    case credit
}

struct WatchCivilDayV1: Codable, Equatable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) throws {
        guard (1...9_999).contains(year), (1...12).contains(month), (1...31).contains(day) else {
            throw WatchTimeEntryContractError.invalidDay
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: 12
        )
        guard
            let date = calendar.date(from: components),
            calendar.component(.year, from: date) == year,
            calendar.component(.month, from: date) == month,
            calendar.component(.day, from: date) == day
        else {
            throw WatchTimeEntryContractError.invalidDay
        }
        self.year = year
        self.month = month
        self.day = day
    }

    init(_ date: Date, timeZone: TimeZone = .current) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        try self.init(
            year: calendar.component(.year, from: date),
            month: calendar.component(.month, from: date),
            day: calendar.component(.day, from: date)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case year
        case month
        case day
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            year: container.decode(Int.self, forKey: .year),
            month: container.decode(Int.self, forKey: .month),
            day: container.decode(Int.self, forKey: .day)
        )
    }
}

enum WatchTimeEntryContractError: Error, Equatable, Sendable {
    case payloadTooLarge
    case invalidPayload
    case unsupportedVersion
    case invalidDay
    case invalidHours
    case invalidMinutes
    case emptyDuration
    case durationTooLarge
    case invalidTimestamp
    case responseMismatch
}

enum WatchTimeEntryDurationV1 {
    static func totalMinutes(hours: Int, minutes: Int) throws -> Int {
        guard (0...99).contains(hours) else {
            throw WatchTimeEntryContractError.invalidHours
        }
        guard (0...59).contains(minutes) else {
            throw WatchTimeEntryContractError.invalidMinutes
        }
        let total = hours * 60 + minutes
        guard total > 0 else {
            throw WatchTimeEntryContractError.emptyDuration
        }
        guard total <= 5_999 else {
            throw WatchTimeEntryContractError.durationTooLarge
        }
        return total
    }

    /// Converts the duration Siri resolves from natural speech into the
    /// whole-minute value stored by Hourleaf. Fractional minutes are rejected
    /// rather than silently changing what the user said.
    static func totalMinutes(duration: Measurement<UnitDuration>) throws -> Int {
        let minuteValue = duration.converted(to: .minutes).value
        guard minuteValue.isFinite else {
            throw WatchTimeEntryContractError.invalidMinutes
        }

        let roundedMinutes = minuteValue.rounded()
        let tolerance = max(1, abs(minuteValue)) * 1e-9
        guard abs(minuteValue - roundedMinutes) <= tolerance else {
            throw WatchTimeEntryContractError.invalidMinutes
        }
        guard roundedMinutes > 0 else {
            throw WatchTimeEntryContractError.emptyDuration
        }
        guard roundedMinutes <= 5_999 else {
            throw WatchTimeEntryContractError.durationTooLarge
        }
        return Int(roundedMinutes)
    }
}

struct WatchTimeEntryEnvelopeV1: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let maximumEncodedBytes = 4_096

    let version: Int
    let mutationID: UUID
    let entryID: UUID
    let kind: WatchTimeEntryKindV1
    let day: WatchCivilDayV1
    let minutes: Int
    let occurredAt: Date

    init(
        mutationID: UUID = UUID(),
        entryID: UUID = UUID(),
        kind: WatchTimeEntryKindV1,
        day: WatchCivilDayV1,
        minutes: Int,
        occurredAt: Date = .now
    ) throws {
        guard (1...5_999).contains(minutes) else {
            throw minutes <= 0
                ? WatchTimeEntryContractError.emptyDuration
                : WatchTimeEntryContractError.durationTooLarge
        }
        let timestamp = occurredAt.timeIntervalSince1970
        guard timestamp.isFinite, timestamp >= 0 else {
            throw WatchTimeEntryContractError.invalidTimestamp
        }
        version = Self.currentVersion
        self.mutationID = mutationID
        self.entryID = entryID
        self.kind = kind
        self.day = day
        self.minutes = minutes
        self.occurredAt = occurredAt
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case mutationID
        case entryID
        case kind
        case day
        case minutes
        case occurredAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decode(Int.self, forKey: .version)
        guard decodedVersion == Self.currentVersion else {
            throw WatchTimeEntryContractError.unsupportedVersion
        }
        try self.init(
            mutationID: container.decode(UUID.self, forKey: .mutationID),
            entryID: container.decode(UUID.self, forKey: .entryID),
            kind: container.decode(WatchTimeEntryKindV1.self, forKey: .kind),
            day: container.decode(WatchCivilDayV1.self, forKey: .day),
            minutes: container.decode(Int.self, forKey: .minutes),
            occurredAt: container.decode(Date.self, forKey: .occurredAt)
        )
    }

    func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data: Data
        do {
            data = try encoder.encode(self)
        } catch {
            throw WatchTimeEntryContractError.invalidPayload
        }
        guard data.count <= Self.maximumEncodedBytes else {
            throw WatchTimeEntryContractError.payloadTooLarge
        }
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumEncodedBytes else {
            throw data.count > maximumEncodedBytes
                ? WatchTimeEntryContractError.payloadTooLarge
                : WatchTimeEntryContractError.invalidPayload
        }
        do {
            return try PropertyListDecoder().decode(Self.self, from: data)
        } catch let error as WatchTimeEntryContractError {
            throw error
        } catch {
            throw WatchTimeEntryContractError.invalidPayload
        }
    }
}

enum WatchTimeEntryResponseStatusV1: String, Codable, Sendable {
    case saved
    case replayed
    case rejected
    case failed
}

struct WatchTimeEntryResponseV1: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let maximumEncodedBytes = 1_024

    let version: Int
    let mutationID: UUID
    let status: WatchTimeEntryResponseStatusV1

    init(
        mutationID: UUID,
        status: WatchTimeEntryResponseStatusV1
    ) {
        version = Self.currentVersion
        self.mutationID = mutationID
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case mutationID
        case status
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decode(Int.self, forKey: .version)
        guard decodedVersion == Self.currentVersion else {
            throw WatchTimeEntryContractError.unsupportedVersion
        }
        version = decodedVersion
        mutationID = try container.decode(UUID.self, forKey: .mutationID)
        status = try container.decode(WatchTimeEntryResponseStatusV1.self, forKey: .status)
    }

    func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data: Data
        do {
            data = try encoder.encode(self)
        } catch {
            throw WatchTimeEntryContractError.invalidPayload
        }
        guard data.count <= Self.maximumEncodedBytes else {
            throw WatchTimeEntryContractError.payloadTooLarge
        }
        return data
    }

    static func decode(
        _ data: Data,
        expecting mutationID: UUID
    ) throws -> Self {
        guard !data.isEmpty, data.count <= maximumEncodedBytes else {
            throw data.count > maximumEncodedBytes
                ? WatchTimeEntryContractError.payloadTooLarge
                : WatchTimeEntryContractError.invalidPayload
        }
        let response: Self
        do {
            response = try PropertyListDecoder().decode(Self.self, from: data)
        } catch let error as WatchTimeEntryContractError {
            throw error
        } catch {
            throw WatchTimeEntryContractError.invalidPayload
        }
        guard response.mutationID == mutationID else {
            throw WatchTimeEntryContractError.responseMismatch
        }
        return response
    }
}
