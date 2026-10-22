import Foundation
import UserNotifications

/// Delegate is installed before application launch completes; no remote registration.
final class LocalNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = LocalNotifications()
    static let identifier = "bookoo-hydration-idle"

    func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    @MainActor static func send(total: Double, goal: Double, test: Bool = false) async throws {
        let content = UNMutableNotificationContent()
        content.title = test ? "BookooHydration 测试通知" : "该喝点水了 💧"
        content.body = test ? "本机通知已提交。饮水记录不会因此改变。" : String(format: "今日已记录 %.0f / %.0f mL。喝水后请空秤开机，再放回水杯称量。", total, goal)
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try await UNUserNotificationCenter.current().add(request)
    }
}
