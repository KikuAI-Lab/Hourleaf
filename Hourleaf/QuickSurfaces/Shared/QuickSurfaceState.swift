import Foundation

enum QuickSurfacePrivacyModeV1: String, Codable, CaseIterable, Sendable {
    case hideTotals
    case showTotals
}

enum QuickSurfaceClockAssessmentV1: String, Codable, CaseIterable, Sendable {
    case sameBootMonotonic
    case recoveredWallClock
    case manualRequired
}

enum QuickSurfaceAuthorizedKindV1: String, Codable, CaseIterable, Sendable {
    case service
    case credit
}

struct QuickSurfaceProjectionV1: Equatable, Sendable {
    let privacyMode: QuickSurfacePrivacyModeV1
    let monthKey: String?
    let timeZoneIdentifier: String?
    let serviceMinutes: Int?
    let creditMinutes: Int?
    let generatedAtEpochSeconds: Double

    init(
        privacyMode: QuickSurfacePrivacyModeV1,
        monthKey: String?,
        timeZoneIdentifier: String?,
        serviceMinutes: Int?,
        creditMinutes: Int?,
        generatedAtEpochSeconds: Double
    ) throws {
        try Self.validateGeneratedAt(generatedAtEpochSeconds)
        switch privacyMode {
        case .hideTotals:
            guard
                monthKey == nil,
                timeZoneIdentifier == nil,
                serviceMinutes == nil,
                creditMinutes == nil
            else {
                throw QuickSurfaceStateCodecError.invalidValue(
                    "hideTotals requires all projection totals to be nil"
                )
            }
        case .showTotals:
            guard
                let monthKey,
                let timeZoneIdentifier,
                let serviceMinutes,
                let creditMinutes
            else {
                throw QuickSurfaceStateCodecError.invalidValue(
                    "showTotals requires month, time zone, and both totals"
                )
            }
            try Self.validateMonthKey(monthKey)
            try Self.validateTimeZoneIdentifier(timeZoneIdentifier)
            try Self.validateMinutes(serviceMinutes, path: "projection.serviceMinutes")
            try Self.validateMinutes(creditMinutes, path: "projection.creditMinutes")
        }

        self.privacyMode = privacyMode
        self.monthKey = monthKey
        self.timeZoneIdentifier = timeZoneIdentifier
        self.serviceMinutes = serviceMinutes
        self.creditMinutes = creditMinutes
        self.generatedAtEpochSeconds = generatedAtEpochSeconds
    }

    private static func validateGeneratedAt(_ value: Double) throws {
        guard value.isFinite, value >= 0 else {
            throw QuickSurfaceStateCodecError.invalidValue(
                "projection.generatedAtEpochSeconds must be finite and nonnegative"
            )
        }
    }

    fileprivate static func validateMonthKey(_ value: String) throws {
        let components = value.split(separator: "-", omittingEmptySubsequences: false)
        guard
            components.count == 2,
            let year = Int(components[0]),
            let month = Int(components[1]),
            value == String(format: "%04d-%02d", year, month),
            (1...9_999).contains(year),
            (1...12).contains(month)
        else {
            throw QuickSurfaceStateCodecError.invalidValue("projection.monthKey must be YYYY-MM")
        }
    }

    fileprivate static func validateTimeZoneIdentifier(_ value: String) throws {
        let byteCount = value.utf8.count
        guard
            (1...128).contains(byteCount),
            TimeZone.knownTimeZoneIdentifiers.contains(value)
        else {
            throw QuickSurfaceStateCodecError.invalidValue(
                "projection.timeZoneIdentifier must be an existing IANA identifier"
            )
        }
    }

    fileprivate static func validateMinutes(_ value: Int, path: String) throws {
        guard (0...Int(Int32.max)).contains(value) else {
            throw QuickSurfaceStateCodecError.invalidValue("\(path) must be in 0...Int32.max")
        }
    }
}

extension QuickSurfaceProjectionV1: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case privacyMode
        case monthKey
        case timeZoneIdentifier
        case serviceMinutes
        case creditMinutes
        case generatedAtEpochSeconds
    }

    init(from decoder: any Decoder) throws {
        let rawContainer = try decoder.container(keyedBy: QuickSurfaceAnyCodingKey.self)
        try QuickSurfaceStrictJSON.requireExactKeys(
            actual: rawContainer.allKeys.map(\.stringValue),
            expected: CodingKeys.allCases.map(\.stringValue),
            path: "projection"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let privacyMode = try container.decode(QuickSurfacePrivacyModeV1.self, forKey: .privacyMode)
        let monthKeyString = try container.decodeNil(forKey: .monthKey) ? nil : try container.decode(String.self, forKey: .monthKey)
        let timeZoneIdentifier = try container.decodeNil(forKey: .timeZoneIdentifier) ? nil : try container.decode(String.self, forKey: .timeZoneIdentifier)
        let serviceMinutes = try container.decodeNil(forKey: .serviceMinutes) ? nil : try container.decode(Int.self, forKey: .serviceMinutes)
        let creditMinutes = try container.decodeNil(forKey: .creditMinutes) ? nil : try container.decode(Int.self, forKey: .creditMinutes)
        let generatedAtEpochSeconds = try container.decode(Double.self, forKey: .generatedAtEpochSeconds)

        if let monthKeyString {
            try Self.validateMonthKey(monthKeyString)
        }

        try self.init(
            privacyMode: privacyMode,
            monthKey: monthKeyString,
            timeZoneIdentifier: timeZoneIdentifier,
            serviceMinutes: serviceMinutes,
            creditMinutes: creditMinutes,
            generatedAtEpochSeconds: generatedAtEpochSeconds
        )
    }

    func encode(to encoder: any Encoder) throws {
        try Self.validateGeneratedAt(generatedAtEpochSeconds)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(privacyMode, forKey: .privacyMode)
        if let monthKey {
            try Self.validateMonthKey(monthKey)
            try container.encode(monthKey, forKey: .monthKey)
        } else {
            try container.encodeNil(forKey: .monthKey)
        }
        if let timeZoneIdentifier {
            try Self.validateTimeZoneIdentifier(timeZoneIdentifier)
            try container.encode(timeZoneIdentifier, forKey: .timeZoneIdentifier)
        } else {
            try container.encodeNil(forKey: .timeZoneIdentifier)
        }
        if let serviceMinutes {
            try Self.validateMinutes(serviceMinutes, path: "projection.serviceMinutes")
            try container.encode(serviceMinutes, forKey: .serviceMinutes)
        } else {
            try container.encodeNil(forKey: .serviceMinutes)
        }
        if let creditMinutes {
            try Self.validateMinutes(creditMinutes, path: "projection.creditMinutes")
            try container.encode(creditMinutes, forKey: .creditMinutes)
        } else {
            try container.encodeNil(forKey: .creditMinutes)
        }
        try container.encode(generatedAtEpochSeconds, forKey: .generatedAtEpochSeconds)
    }
}

enum TimerSessionV1: Equatable, Sendable {
    case idle
    case running(Running)
    case reviewPending(ReviewPending)
    case finalizing(Finalizing)

    struct Running: Equatable, Sendable {
        let sessionID: UUID
        let startedAtEpochSeconds: Double
        let startedSystemUptimeSeconds: Double

        init(
            sessionID: UUID,
            startedAtEpochSeconds: Double,
            startedSystemUptimeSeconds: Double
        ) throws {
            try QuickSurfaceStrictJSON.validateFiniteNonnegative(
                startedAtEpochSeconds,
                path: "timer.startedAtEpochSeconds"
            )
            try QuickSurfaceStrictJSON.validateFiniteNonnegative(
                startedSystemUptimeSeconds,
                path: "timer.startedSystemUptimeSeconds"
            )
            self.sessionID = sessionID
            self.startedAtEpochSeconds = startedAtEpochSeconds
            self.startedSystemUptimeSeconds = startedSystemUptimeSeconds
        }
    }

    struct ReviewPending: Equatable, Sendable {
        let sessionID: UUID
        let startedAtEpochSeconds: Double
        let stoppedAtEpochSeconds: Double
        let elapsedSeconds: Int64
        let clockAssessment: QuickSurfaceClockAssessmentV1
        let suggestedMinutes: Int?
        let mutationID: UUID
        let entryID: UUID

        init(
            sessionID: UUID,
            startedAtEpochSeconds: Double,
            stoppedAtEpochSeconds: Double,
            elapsedSeconds: Int64,
            clockAssessment: QuickSurfaceClockAssessmentV1,
            suggestedMinutes: Int?,
            mutationID: UUID,
            entryID: UUID
        ) throws {
            try QuickSurfaceStrictJSON.validateFiniteNonnegative(
                startedAtEpochSeconds,
                path: "timer.startedAtEpochSeconds"
            )
            try QuickSurfaceStrictJSON.validateFiniteNonnegative(
                stoppedAtEpochSeconds,
                path: "timer.stoppedAtEpochSeconds"
            )
            try QuickSurfaceStrictJSON.validateElapsedSeconds(elapsedSeconds, path: "timer.elapsedSeconds")
            try QuickSurfaceStrictJSON.validateSuggestedMinutes(suggestedMinutes, path: "timer.suggestedMinutes")
            self.sessionID = sessionID
            self.startedAtEpochSeconds = startedAtEpochSeconds
            self.stoppedAtEpochSeconds = stoppedAtEpochSeconds
            self.elapsedSeconds = elapsedSeconds
            self.clockAssessment = clockAssessment
            self.suggestedMinutes = suggestedMinutes
            self.mutationID = mutationID
            self.entryID = entryID
        }
    }

    struct Finalizing: Equatable, Sendable {
        let sessionID: UUID
        let startedAtEpochSeconds: Double
        let stoppedAtEpochSeconds: Double
        let elapsedSeconds: Int64
        let clockAssessment: QuickSurfaceClockAssessmentV1
        let suggestedMinutes: Int?
        let mutationID: UUID
        let entryID: UUID
        let authorizedKind: QuickSurfaceAuthorizedKindV1
        let authorizedDay: String
        let authorizedMinutes: Int
        let authorizedAtEpochSeconds: Double

        init(
            sessionID: UUID,
            startedAtEpochSeconds: Double,
            stoppedAtEpochSeconds: Double,
            elapsedSeconds: Int64,
            clockAssessment: QuickSurfaceClockAssessmentV1,
            suggestedMinutes: Int?,
            mutationID: UUID,
            entryID: UUID,
            authorizedKind: QuickSurfaceAuthorizedKindV1,
            authorizedDay: String,
            authorizedMinutes: Int,
            authorizedAtEpochSeconds: Double
        ) throws {
            try QuickSurfaceStrictJSON.validateFiniteNonnegative(
                startedAtEpochSeconds,
                path: "timer.startedAtEpochSeconds"
            )
            try QuickSurfaceStrictJSON.validateFiniteNonnegative(
                stoppedAtEpochSeconds,
                path: "timer.stoppedAtEpochSeconds"
            )
            try QuickSurfaceStrictJSON.validateElapsedSeconds(elapsedSeconds, path: "timer.elapsedSeconds")
            try QuickSurfaceStrictJSON.validateSuggestedMinutes(suggestedMinutes, path: "timer.suggestedMinutes")
            try QuickSurfaceStrictJSON.validateLocalDayKey(authorizedDay, path: "timer.authorizedDay")
            guard (1...5_999).contains(authorizedMinutes) else {
                throw QuickSurfaceStateCodecError.invalidValue(
                    "timer.authorizedMinutes must be in 1...5999"
                )
            }
            try QuickSurfaceStrictJSON.validateFiniteNonnegative(
                authorizedAtEpochSeconds,
                path: "timer.authorizedAtEpochSeconds"
            )
            self.sessionID = sessionID
            self.startedAtEpochSeconds = startedAtEpochSeconds
            self.stoppedAtEpochSeconds = stoppedAtEpochSeconds
            self.elapsedSeconds = elapsedSeconds
            self.clockAssessment = clockAssessment
            self.suggestedMinutes = suggestedMinutes
            self.mutationID = mutationID
            self.entryID = entryID
            self.authorizedKind = authorizedKind
            self.authorizedDay = authorizedDay
            self.authorizedMinutes = authorizedMinutes
            self.authorizedAtEpochSeconds = authorizedAtEpochSeconds
        }
    }
}

extension TimerSessionV1: Codable {
    private enum Phase: String, Codable {
        case idle
        case running
        case reviewPending
        case finalizing
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case phase
        case sessionID
        case startedAtEpochSeconds
        case startedSystemUptimeSeconds
        case stoppedAtEpochSeconds
        case elapsedSeconds
        case clockAssessment
        case suggestedMinutes
        case mutationID
        case entryID
        case authorizedKind
        case authorizedDay
        case authorizedMinutes
        case authorizedAtEpochSeconds
    }

    init(from decoder: any Decoder) throws {
        let rawContainer = try decoder.container(keyedBy: QuickSurfaceAnyCodingKey.self)
        let rawKeys = rawContainer.allKeys.map(\.stringValue)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let phase = try container.decode(Phase.self, forKey: .phase)

        switch phase {
        case .idle:
            try QuickSurfaceStrictJSON.requireExactKeys(
                actual: rawKeys,
                expected: [CodingKeys.phase.rawValue],
                path: "timer"
            )
            self = .idle

        case .running:
            try QuickSurfaceStrictJSON.requireExactKeys(
                actual: rawKeys,
                expected: [
                    CodingKeys.phase.rawValue,
                    CodingKeys.sessionID.rawValue,
                    CodingKeys.startedAtEpochSeconds.rawValue,
                    CodingKeys.startedSystemUptimeSeconds.rawValue
                ],
                path: "timer"
            )
            self = .running(
                try .init(
                    sessionID: container.decode(UUID.self, forKey: .sessionID),
                    startedAtEpochSeconds: container.decode(Double.self, forKey: .startedAtEpochSeconds),
                    startedSystemUptimeSeconds: container.decode(Double.self, forKey: .startedSystemUptimeSeconds)
                )
            )

        case .reviewPending:
            try QuickSurfaceStrictJSON.requireExactKeys(
                actual: rawKeys,
                expected: [
                    CodingKeys.phase.rawValue,
                    CodingKeys.sessionID.rawValue,
                    CodingKeys.startedAtEpochSeconds.rawValue,
                    CodingKeys.stoppedAtEpochSeconds.rawValue,
                    CodingKeys.elapsedSeconds.rawValue,
                    CodingKeys.clockAssessment.rawValue,
                    CodingKeys.suggestedMinutes.rawValue,
                    CodingKeys.mutationID.rawValue,
                    CodingKeys.entryID.rawValue
                ],
                path: "timer"
            )
            self = .reviewPending(
                try .init(
                    sessionID: container.decode(UUID.self, forKey: .sessionID),
                    startedAtEpochSeconds: container.decode(Double.self, forKey: .startedAtEpochSeconds),
                    stoppedAtEpochSeconds: container.decode(Double.self, forKey: .stoppedAtEpochSeconds),
                    elapsedSeconds: container.decode(Int64.self, forKey: .elapsedSeconds),
                    clockAssessment: container.decode(QuickSurfaceClockAssessmentV1.self, forKey: .clockAssessment),
                    suggestedMinutes: container.decodeNil(forKey: .suggestedMinutes) ? nil : container.decode(Int.self, forKey: .suggestedMinutes),
                    mutationID: container.decode(UUID.self, forKey: .mutationID),
                    entryID: container.decode(UUID.self, forKey: .entryID)
                )
            )

        case .finalizing:
            try QuickSurfaceStrictJSON.requireExactKeys(
                actual: rawKeys,
                expected: [
                    CodingKeys.phase.rawValue,
                    CodingKeys.sessionID.rawValue,
                    CodingKeys.startedAtEpochSeconds.rawValue,
                    CodingKeys.stoppedAtEpochSeconds.rawValue,
                    CodingKeys.elapsedSeconds.rawValue,
                    CodingKeys.clockAssessment.rawValue,
                    CodingKeys.suggestedMinutes.rawValue,
                    CodingKeys.mutationID.rawValue,
                    CodingKeys.entryID.rawValue,
                    CodingKeys.authorizedKind.rawValue,
                    CodingKeys.authorizedDay.rawValue,
                    CodingKeys.authorizedMinutes.rawValue,
                    CodingKeys.authorizedAtEpochSeconds.rawValue
                ],
                path: "timer"
            )

            let authorizedDay = try container.decode(String.self, forKey: .authorizedDay)
            try QuickSurfaceStrictJSON.validateLocalDayKey(authorizedDay, path: "timer.authorizedDay")

            self = .finalizing(
                try .init(
                    sessionID: container.decode(UUID.self, forKey: .sessionID),
                    startedAtEpochSeconds: container.decode(Double.self, forKey: .startedAtEpochSeconds),
                    stoppedAtEpochSeconds: container.decode(Double.self, forKey: .stoppedAtEpochSeconds),
                    elapsedSeconds: container.decode(Int64.self, forKey: .elapsedSeconds),
                    clockAssessment: container.decode(QuickSurfaceClockAssessmentV1.self, forKey: .clockAssessment),
                    suggestedMinutes: container.decodeNil(forKey: .suggestedMinutes) ? nil : container.decode(Int.self, forKey: .suggestedMinutes),
                    mutationID: container.decode(UUID.self, forKey: .mutationID),
                    entryID: container.decode(UUID.self, forKey: .entryID),
                    authorizedKind: container.decode(QuickSurfaceAuthorizedKindV1.self, forKey: .authorizedKind),
                    authorizedDay: authorizedDay,
                    authorizedMinutes: container.decode(Int.self, forKey: .authorizedMinutes),
                    authorizedAtEpochSeconds: container.decode(Double.self, forKey: .authorizedAtEpochSeconds)
                )
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .idle:
            try container.encode(Phase.idle, forKey: .phase)

        case let .running(running):
            try container.encode(Phase.running, forKey: .phase)
            try container.encode(running.sessionID, forKey: .sessionID)
            try container.encode(running.startedAtEpochSeconds, forKey: .startedAtEpochSeconds)
            try container.encode(running.startedSystemUptimeSeconds, forKey: .startedSystemUptimeSeconds)

        case let .reviewPending(reviewPending):
            try container.encode(Phase.reviewPending, forKey: .phase)
            try container.encode(reviewPending.sessionID, forKey: .sessionID)
            try container.encode(reviewPending.startedAtEpochSeconds, forKey: .startedAtEpochSeconds)
            try container.encode(reviewPending.stoppedAtEpochSeconds, forKey: .stoppedAtEpochSeconds)
            try container.encode(reviewPending.elapsedSeconds, forKey: .elapsedSeconds)
            try container.encode(reviewPending.clockAssessment, forKey: .clockAssessment)
            if let suggestedMinutes = reviewPending.suggestedMinutes {
                try container.encode(suggestedMinutes, forKey: .suggestedMinutes)
            } else {
                try container.encodeNil(forKey: .suggestedMinutes)
            }
            try container.encode(reviewPending.mutationID, forKey: .mutationID)
            try container.encode(reviewPending.entryID, forKey: .entryID)

        case let .finalizing(finalizing):
            try container.encode(Phase.finalizing, forKey: .phase)
            try container.encode(finalizing.sessionID, forKey: .sessionID)
            try container.encode(finalizing.startedAtEpochSeconds, forKey: .startedAtEpochSeconds)
            try container.encode(finalizing.stoppedAtEpochSeconds, forKey: .stoppedAtEpochSeconds)
            try container.encode(finalizing.elapsedSeconds, forKey: .elapsedSeconds)
            try container.encode(finalizing.clockAssessment, forKey: .clockAssessment)
            if let suggestedMinutes = finalizing.suggestedMinutes {
                try container.encode(suggestedMinutes, forKey: .suggestedMinutes)
            } else {
                try container.encodeNil(forKey: .suggestedMinutes)
            }
            try container.encode(finalizing.mutationID, forKey: .mutationID)
            try container.encode(finalizing.entryID, forKey: .entryID)
            try container.encode(finalizing.authorizedKind, forKey: .authorizedKind)
            try QuickSurfaceStrictJSON.validateLocalDayKey(finalizing.authorizedDay, path: "timer.authorizedDay")
            try container.encode(finalizing.authorizedDay, forKey: .authorizedDay)
            try container.encode(finalizing.authorizedMinutes, forKey: .authorizedMinutes)
            try container.encode(finalizing.authorizedAtEpochSeconds, forKey: .authorizedAtEpochSeconds)
        }
    }
}

struct QuickSurfaceStateV1: Equatable, Sendable {
    static let schemaVersion = 1
    static let maximumFileBytes = 16 * 1_024

    let revision: UInt64
    let projection: QuickSurfaceProjectionV1
    let timerEnabled: Bool
    let timer: TimerSessionV1

    init(
        revision: UInt64,
        projection: QuickSurfaceProjectionV1,
        timerEnabled: Bool,
        timer: TimerSessionV1
    ) {
        self.revision = revision
        self.projection = projection
        self.timerEnabled = timerEnabled
        self.timer = timer
    }

    static func idleHidden(revision: UInt64 = 1) throws -> QuickSurfaceStateV1 {
        QuickSurfaceStateV1(
            revision: revision,
            projection: try QuickSurfaceProjectionV1(
                privacyMode: .hideTotals,
                monthKey: nil,
                timeZoneIdentifier: nil,
                serviceMinutes: nil,
                creditMinutes: nil,
                generatedAtEpochSeconds: 0
            ),
            timerEnabled: false,
            timer: .idle
        )
    }

    func nextRevision() throws -> UInt64 {
        guard revision < .max else {
            throw QuickSurfaceStateCodecError.invalidValue("state.revision cannot exceed UInt64.max")
        }
        return revision + 1
    }

    static func encodeCanonical(_ state: QuickSurfaceStateV1) throws -> Data {
        let data = try QuickSurfaceStrictJSON.canonicalData(state)
        guard data.count <= maximumFileBytes else {
            throw QuickSurfaceStateCodecError.fileTooLarge(actual: data.count, limit: maximumFileBytes)
        }
        return data
    }

    static func decodeStrict(_ data: Data) throws -> QuickSurfaceStateV1 {
        guard data.count <= maximumFileBytes else {
            throw QuickSurfaceStateCodecError.fileTooLarge(actual: data.count, limit: maximumFileBytes)
        }

        let state: QuickSurfaceStateV1
        do {
            state = try JSONDecoder().decode(QuickSurfaceStateV1.self, from: data)
        } catch let error as QuickSurfaceStateCodecError {
            throw error
        } catch {
            throw QuickSurfaceStateCodecError.invalidJSON(error.localizedDescription)
        }

        guard try QuickSurfaceStrictJSON.canonicalData(state) == data else {
            throw QuickSurfaceStateCodecError.nonCanonicalJSON
        }

        return state
    }
}

extension QuickSurfaceStateV1: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case revision
        case projection
        case timerEnabled
        case timer
    }

    init(from decoder: any Decoder) throws {
        let rawContainer = try decoder.container(keyedBy: QuickSurfaceAnyCodingKey.self)
        try QuickSurfaceStrictJSON.requireExactKeys(
            actual: rawContainer.allKeys.map(\.stringValue),
            expected: CodingKeys.allCases.map(\.stringValue),
            path: "state"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.schemaVersion else {
            throw QuickSurfaceStateCodecError.unsupportedVersion(schemaVersion)
        }

        self.init(
            revision: try container.decode(UInt64.self, forKey: .revision),
            projection: try container.decode(QuickSurfaceProjectionV1.self, forKey: .projection),
            timerEnabled: try container.decode(Bool.self, forKey: .timerEnabled),
            timer: try container.decode(TimerSessionV1.self, forKey: .timer)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(revision, forKey: .revision)
        try container.encode(projection, forKey: .projection)
        try container.encode(timerEnabled, forKey: .timerEnabled)
        try container.encode(timer, forKey: .timer)
    }
}

enum QuickSurfaceStateCodecError: LocalizedError, Equatable, Sendable {
    case fileTooLarge(actual: Int, limit: Int)
    case invalidJSON(String)
    case nonCanonicalJSON
    case unsupportedVersion(Int)
    case wrongKeys(path: String, expected: [String], actual: [String])
    case invalidValue(String)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return "Quick-surface state is larger than the supported limit."
        case .invalidJSON:
            return "Quick-surface state is not valid JSON."
        case .nonCanonicalJSON:
            return "Quick-surface state is not in canonical JSON form."
        case .unsupportedVersion:
            return "Quick-surface state uses an unsupported version."
        case let .wrongKeys(path, _, _):
            return "Quick-surface state fields do not match the \(path) schema."
        case let .invalidValue(reason):
            return reason
        }
    }
}

private enum QuickSurfaceStrictJSON {
    static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func requireExactKeys(actual: [String], expected: [String], path: String) throws {
        let actualSet = Set(actual)
        let expectedSet = Set(expected)
        guard actualSet == expectedSet, actual.count == expected.count else {
            throw QuickSurfaceStateCodecError.wrongKeys(
                path: path,
                expected: expected.sorted(),
                actual: actual.sorted()
            )
        }
    }

    static func validateFiniteNonnegative(_ value: Double, path: String) throws {
        guard value.isFinite, value >= 0 else {
            throw QuickSurfaceStateCodecError.invalidValue("\(path) must be finite and nonnegative")
        }
    }

    static func validateElapsedSeconds(_ value: Int64, path: String) throws {
        guard value >= 0 else {
            throw QuickSurfaceStateCodecError.invalidValue("\(path) must be >= 0")
        }
    }

    static func validateSuggestedMinutes(_ value: Int?, path: String) throws {
        guard let value else { return }
        guard (1...5_999).contains(value) else {
            throw QuickSurfaceStateCodecError.invalidValue("\(path) must be nil or in 1...5999")
        }
    }

    static func validateLocalDayKey(_ value: String, path: String) throws {
        let components = value.split(separator: "-", omittingEmptySubsequences: false)
        guard
            components.count == 3,
            let year = Int(components[0]),
            let month = Int(components[1]),
            let day = Int(components[2]),
            value == String(format: "%04d-%02d-%02d", year, month, day),
            (1...9_999).contains(year),
            (1...12).contains(month),
            (1...31).contains(day)
        else {
            throw QuickSurfaceStateCodecError.invalidValue("\(path) must be YYYY-MM-DD")
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone(identifier: "UTC")!
        guard
            let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)),
            calendar.component(.year, from: date) == year,
            calendar.component(.month, from: date) == month,
            calendar.component(.day, from: date) == day
        else {
            throw QuickSurfaceStateCodecError.invalidValue("\(path) must be YYYY-MM-DD")
        }
    }
}

private struct QuickSurfaceAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
