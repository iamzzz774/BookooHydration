import Foundation

public struct DetectorConfiguration: Codable, Equatable, Sendable {
    public var minimumDrinkGrams: Double
    public var maximumDrinkGrams: Double
    public var cupAwayThresholdGrams: Double
    public var minimumCupReturnGrams: Double
    public var stableDurationSeconds: TimeInterval
    public var stableToleranceGrams: Double

    public init(
        minimumDrinkGrams: Double = 10,
        maximumDrinkGrams: Double = 500,
        cupAwayThresholdGrams: Double = 10,
        minimumCupReturnGrams: Double = 50,
        stableDurationSeconds: TimeInterval = 2,
        stableToleranceGrams: Double = 1
    ) {
        self.minimumDrinkGrams = minimumDrinkGrams
        self.maximumDrinkGrams = maximumDrinkGrams
        self.cupAwayThresholdGrams = cupAwayThresholdGrams
        self.minimumCupReturnGrams = minimumCupReturnGrams
        self.stableDurationSeconds = stableDurationSeconds
        self.stableToleranceGrams = stableToleranceGrams
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var dailyGoalML: Double
    public var enabledWeekdays: Set<Weekday>
    public var windows: [MonitoringWindow]
    public var detector: DetectorConfiguration
    public var emptyCupWeightG: Double?
    public var tareFeedbackEnabled: Bool
    public var remindersEnabled: Bool = false
    public var reminderIntervalMinutes: Int = 90
    public var remindersEnabledAt: Date?
    public var autoOffMinutes: Int

    public init(
        dailyGoalML: Double = 2000,
        enabledWeekdays: Set<Weekday> = Set([.monday, .tuesday, .wednesday, .thursday, .friday, .saturday]),
        windows: [MonitoringWindow] = [
            MonitoringWindow(startHour: 9, startMinute: 0, endHour: 12, endMinute: 15),
            MonitoringWindow(startHour: 14, startMinute: 30, endHour: 17, endMinute: 30)
        ],
        detector: DetectorConfiguration = DetectorConfiguration(),
        emptyCupWeightG: Double? = nil,
        tareFeedbackEnabled: Bool = true,
        autoOffMinutes: Int = 5
    ) {
        self.dailyGoalML = dailyGoalML
        self.enabledWeekdays = enabledWeekdays
        self.windows = windows
        self.detector = detector
        self.emptyCupWeightG = emptyCupWeightG
        self.tareFeedbackEnabled = tareFeedbackEnabled
        self.autoOffMinutes = autoOffMinutes
    }

    private enum CodingKeys: String, CodingKey {
        case remindersEnabled, reminderIntervalMinutes, remindersEnabledAt
        case dailyGoalML, enabledWeekdays, windows, detector
        case emptyCupWeightG, tareFeedbackEnabled, autoOffMinutes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dailyGoalML = try container.decodeIfPresent(Double.self, forKey: .dailyGoalML) ?? 2000
        enabledWeekdays = try container.decodeIfPresent(Set<Weekday>.self, forKey: .enabledWeekdays)
            ?? AppSettings.defaults.enabledWeekdays
        windows = try container.decodeIfPresent([MonitoringWindow].self, forKey: .windows)
            ?? AppSettings.defaults.windows
        detector = try container.decodeIfPresent(DetectorConfiguration.self, forKey: .detector)
            ?? DetectorConfiguration()
        emptyCupWeightG = try container.decodeIfPresent(Double.self, forKey: .emptyCupWeightG)
        tareFeedbackEnabled = try container.decodeIfPresent(Bool.self, forKey: .tareFeedbackEnabled) ?? true
        remindersEnabled = try container.decodeIfPresent(Bool.self, forKey: .remindersEnabled) ?? false
        reminderIntervalMinutes = try container.decodeIfPresent(Int.self, forKey: .reminderIntervalMinutes) ?? 90
        remindersEnabledAt = try container.decodeIfPresent(Date.self, forKey: .remindersEnabledAt)
        autoOffMinutes = try container.decodeIfPresent(Int.self, forKey: .autoOffMinutes) ?? 5
    }

    public static let defaults = AppSettings()

    public mutating func normalize() {
        dailyGoalML = dailyGoalML.clamped(to: 100...10_000)
        detector.minimumDrinkGrams = detector.minimumDrinkGrams.clamped(to: 1...500)
        detector.maximumDrinkGrams = detector.maximumDrinkGrams.clamped(to: detector.minimumDrinkGrams...2_000)
        detector.cupAwayThresholdGrams = detector.cupAwayThresholdGrams.clamped(to: 0...100)
        detector.minimumCupReturnGrams = detector.minimumCupReturnGrams.clamped(to: (detector.cupAwayThresholdGrams + 1)...2_000)
        detector.stableDurationSeconds = detector.stableDurationSeconds.clamped(to: 0.5...10)
        detector.stableToleranceGrams = detector.stableToleranceGrams.clamped(to: 0.1...10)
        if let emptyCupWeightG { self.emptyCupWeightG = emptyCupWeightG.clamped(to: 20...2_000) }
        reminderIntervalMinutes = reminderIntervalMinutes.clamped(to: 15...240)
        autoOffMinutes = autoOffMinutes.clamped(to: 5...30)
        windows = windows.map {
            let start = $0.startMinute.clamped(to: 0...1438)
            let end = max($0.endMinute.clamped(to: 1...1439), start + 1)
            return MonitoringWindow(id: $0.id, startMinute: start, endMinute: end)
        }
        if windows.isEmpty {
            windows = Self.defaults.windows
        }
    }

    public func window(id: UUID) -> MonitoringWindow? {
        windows.first { $0.id == id }
    }

    @discardableResult
    public mutating func setWindowStartMinute(_ minute: Int, id: UUID) -> Bool {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return false }
        let start = minute.clamped(to: 0...1438)
        windows[index].startMinute = start
        windows[index].endMinute = max(windows[index].endMinute, start + 1)
        return true
    }

    @discardableResult
    public mutating func setWindowEndMinute(_ minute: Int, id: UUID) -> Bool {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return false }
        let end = minute.clamped(to: 1...1439)
        windows[index].endMinute = end
        windows[index].startMinute = min(windows[index].startMinute, end - 1)
        return true
    }

    @discardableResult
    public mutating func removeWindow(id: UUID) -> Bool {
        guard windows.count > 1,
              let index = windows.firstIndex(where: { $0.id == id }) else { return false }
        windows.remove(at: index)
        return true
    }
}

public struct HydrationEntry: Codable, Equatable, Identifiable, Sendable {
    public var timestamp: Date
    public var amountML: Double
    public var before: Double
    public var after: Double

    public init(timestamp: Date, amountML: Double, before: Double, after: Double) {
        self.timestamp = timestamp
        self.amountML = amountML
        self.before = before
        self.after = after
    }

    public var id: String {
        "\(timestamp.timeIntervalSince1970)-\(before)-\(after)"
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp, amountML, before, after
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        amountML = try container.decode(Double.self, forKey: .amountML)
        before = try container.decode(Double.self, forKey: .before)
        after = try container.decode(Double.self, forKey: .after)

        if let text = try? container.decode(String.self, forKey: .timestamp),
           let parsed = Self.parseDate(text) {
            timestamp = parsed
        } else if let numeric = try? container.decode(Double.self, forKey: .timestamp) {
            if numeric > 100_000_000_000 {
                timestamp = Date(timeIntervalSince1970: numeric / 1_000)
            } else if numeric >= 1_000_000_000 {
                timestamp = Date(timeIntervalSince1970: numeric)
            } else {
                timestamp = Date(timeIntervalSinceReferenceDate: numeric)
            }
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .timestamp,
                in: container,
                debugDescription: "timestamp must be an ISO-8601 string or numeric epoch"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.formatDate(timestamp), forKey: .timestamp)
        try container.encode(amountML, forKey: .amountML)
        try container.encode(before, forKey: .before)
        try container.encode(after, forKey: .after)
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func parseDate(_ text: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: text) { return date }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

public struct HydrationData: Codable, Equatable, Sendable {
    public var dailyTargetML: Double
    public var lastCupWeightG: Double?
    public var entries: [HydrationEntry]

    public init(dailyTargetML: Double = 2000, lastCupWeightG: Double? = nil, entries: [HydrationEntry] = []) {
        self.dailyTargetML = dailyTargetML
        self.lastCupWeightG = lastCupWeightG
        self.entries = entries
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
