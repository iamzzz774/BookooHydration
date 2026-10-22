import Foundation

public enum Weekday: Int, Codable, CaseIterable, Hashable, Sendable {
    case sunday = 1
    case monday = 2
    case tuesday = 3
    case wednesday = 4
    case thursday = 5
    case friday = 6
    case saturday = 7

    public var chineseName: String {
        switch self {
        case .monday: "周一"
        case .tuesday: "周二"
        case .wednesday: "周三"
        case .thursday: "周四"
        case .friday: "周五"
        case .saturday: "周六"
        case .sunday: "周日"
        }
    }

    public static var mondayFirst: [Weekday] {
        [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]
    }
}

public struct MonitoringWindow: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var startMinute: Int
    public var endMinute: Int

    public init(id: UUID = UUID(), startHour: Int, startMinute: Int, endHour: Int, endMinute: Int) {
        self.id = id
        self.startMinute = startHour * 60 + startMinute
        self.endMinute = endHour * 60 + endMinute
    }

    public init(id: UUID = UUID(), startMinute: Int, endMinute: Int) {
        self.id = id
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    private enum CodingKeys: String, CodingKey {
        case id, startMinute, endMinute
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        startMinute = try container.decode(Int.self, forKey: .startMinute)
        endMinute = try container.decode(Int.self, forKey: .endMinute)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(startMinute, forKey: .startMinute)
        try container.encode(endMinute, forKey: .endMinute)
    }

    public var displayText: String {
        "\(Self.timeText(startMinute))–\(Self.timeText(endMinute))"
    }

    public func contains(minuteOfDay: Int) -> Bool {
        startMinute <= minuteOfDay && minuteOfDay < endMinute
    }

    public static func timeText(_ minute: Int) -> String {
        String(format: "%02d:%02d", max(0, minute) / 60, max(0, minute) % 60)
    }
}

public struct ScheduleEvaluation: Equatable, Sendable {
    public let isWithinWindow: Bool
    public let activeWindow: MonitoringWindow?
    public let nextTransition: Date?

    public init(isWithinWindow: Bool, activeWindow: MonitoringWindow?, nextTransition: Date?) {
        self.isWithinWindow = isWithinWindow
        self.activeWindow = activeWindow
        self.nextTransition = nextTransition
    }
}

public enum ScheduleEvaluator {
    public static func evaluate(
        date: Date,
        enabledWeekdays: Set<Weekday>,
        windows: [MonitoringWindow],
        calendar suppliedCalendar: Calendar = .current
    ) -> ScheduleEvaluation {
        let calendar = suppliedCalendar
        let weekdayValue = calendar.component(.weekday, from: date)
        let minute = calendar.component(.hour, from: date) * 60
            + calendar.component(.minute, from: date)
        let weekday = Weekday(rawValue: weekdayValue)
        let validWindows = windows
            .filter { (0..<1440).contains($0.startMinute) && (1...1440).contains($0.endMinute) && $0.startMinute < $0.endMinute }
            .sorted { $0.startMinute < $1.startMinute }
        let active = enabledWeekdays.contains(weekday ?? .sunday)
            ? validWindows.first(where: { $0.contains(minuteOfDay: minute) })
            : nil

        let startOfToday = calendar.startOfDay(for: date)
        var transitions: [Date] = []
        for dayOffset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday),
                  let candidateWeekday = Weekday(rawValue: calendar.component(.weekday, from: day)),
                  enabledWeekdays.contains(candidateWeekday) else { continue }
            for window in validWindows {
                for transitionMinute in [window.startMinute, window.endMinute] {
                    guard let transition = calendar.date(byAdding: .minute, value: transitionMinute, to: day),
                          transition > date else { continue }
                    transitions.append(transition)
                }
            }
        }

        return ScheduleEvaluation(
            isWithinWindow: active != nil,
            activeWindow: active,
            nextTransition: transitions.min()
        )
    }
}
