import AppKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["BOOKOO_PREVIEW"] != "1" else { return }
        UNUserNotificationCenter.current().delegate = LocalNotifications.shared
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct BookooHydrationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(model: model)
        } label: {
            Image(systemName: model.isPaused ? "drop.slash" : "drop.fill")
                .accessibilityLabel("BookooHydration")
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "drop.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("BookooHydration").font(.headline)
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(isActivelyMonitoring ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("今日")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(model.todayTotalML, format: .number.precision(.fractionLength(0)))
                        .font(.system(size: 32, weight: .semibold, design: .rounded).monospacedDigit())
                    Text("/ \(model.settings.dailyGoalML, specifier: "%.0f") mL")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: progress).tint(.accentColor)
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 10) {
                compactMetric("当前重量", model.currentWeight.map { String(format: "%.1f g", $0) } ?? "—", "scalemass")
                compactMetric("秤电量", model.batteryPercent.map { "\($0)%" } ?? "—", "battery.75percent")
            }

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: activityIcon)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20)
                Text(model.activityMessage)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            if let error = model.errorMessage {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .lineLimit(3)
                    Spacer(minLength: 4)
                    Button("查看") { model.showMainWindow() }
                        .buttonStyle(.link)
                }
                .padding(10)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            Divider()

            HStack(spacing: 8) {
                Button(model.isPaused ? "恢复" : "暂停") { model.togglePause() }
                    .buttonStyle(.borderedProminent)
                Button("扫描") { model.manualScan() }
                    .disabled(!model.canOperateBluetooth)
                Spacer()
                Button("记录与设置…") { model.showMainWindow() }
            }

            HStack {
                Text(model.launchAtLoginEnabled ? "登录时自动启动" : model.launchAtLoginStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 350)
        .onAppear { model.refreshLaunchAtLoginStatus() }
    }

    private var progress: Double {
        guard model.settings.dailyGoalML > 0 else { return 0 }
        return min(max(model.todayTotalML / model.settings.dailyGoalML, 0), 1)
    }

    private var isActivelyMonitoring: Bool {
        model.canOperateBluetooth
    }

    private var statusText: String {
        if model.isPaused { return "监测已暂停" }
        return model.scheduleEvaluation.isWithinWindow ? model.bluetooth.state.chineseText : "等待下个监测时段"
    }

    private var activityIcon: String {
        if model.isPaused { return "pause.circle.fill" }
        if model.bluetooth.state.isConnected { return "checkmark.circle.fill" }
        return "wave.3.right.circle.fill"
    }

    private func compactMetric(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
