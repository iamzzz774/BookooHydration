import Foundation

/// Idle reminders: no server, queued future notifications or catch-up bursts.
public enum ReminderPolicy {
    public static func isDue(now: Date, settings: AppSettings, hydration: HydrationData,
                             lastReminderAt: Date?, paused: Bool,
                             calendar: Calendar = .current) -> Bool {
        guard settings.remindersEnabled, !paused,
              let enabledAt = settings.remindersEnabledAt, enabledAt <= now,
              ScheduleEvaluator.evaluate(date: now, enabledWeekdays: settings.enabledWeekdays,
                  windows: settings.windows, calendar: calendar).isWithinWindow else { return false }
        let startOfDay = calendar.startOfDay(for: now)
        let today = hydration.entries.filter {
            $0.timestamp >= startOfDay && $0.timestamp <= now && $0.amountML.isFinite && $0.amountML > 0
        }
        guard today.reduce(0, { $0 + $1.amountML }) < settings.dailyGoalML else { return false }
        let currentMinute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        // Anchor to the current window, avoiding immediate alerts after a lunch break.
        guard let windowStart = settings.windows.filter({ $0.startMinute <= currentMinute && currentMinute < $0.endMinute })
            .map(\.startMinute).min(),
              let windowDate = calendar.date(bySettingHour: windowStart / 60, minute: windowStart % 60, second: 0, of: now) else { return false }
        let anchor = [enabledAt, windowDate, today.map(\.timestamp).max(), lastReminderAt].compactMap { $0 }.max()!
        return now.timeIntervalSince(anchor) >= Double(settings.reminderIntervalMinutes) * 60
    }
}

public struct ReminderState: Codable, Equatable, Sendable {
    public var lastReminderAt: Date?
    public init(lastReminderAt: Date? = nil) { self.lastReminderAt = lastReminderAt }
}
